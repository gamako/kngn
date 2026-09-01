const std = @import("std");
const pixelops = @import("pixelops");
const vector = @import("vector");
const geom = @import("geom.zig");
const color_mod = @import("color.zig");
const draw_mod = @import("draw.zig");
const font_mod = @import("font.zig");
const path_stroke = @import("path_stroke.zig");
const corner_mask = @import("corner_mask.zig");
const shadow_mask = @import("shadow_mask.zig");

pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const RenderTarget = geom.RenderTarget;
pub const Color = color_mod.Color;
pub const Paint = draw_mod.Paint;
pub const LinearGradient = draw_mod.LinearGradient;
pub const RadialGradient = draw_mod.RadialGradient;
pub const DrawList = draw_mod.DrawList;
pub const BitmapFont = font_mod.BitmapFont;
pub const Font = font_mod.Font;

/// The source bucket a `DrawCmd` is charged to when rendering is profiled.
///
/// **One command is charged to exactly one bucket.** These are the *source* kinds an
/// application emits, not the stages the renderer runs: a sharp outline is drawn as several
/// filled rectangles internally, a circle goes through the rounded implementation, and a
/// stroked path flattens, expands and rasterizes. Those stages overlap across buckets, so
/// bucket times explain how the *scene* is composed, not how the renderer spends its
/// instructions. Do not add stage costs to bucket costs.
pub const RenderBucket = enum {
    sharp_fill,
    rounded_fill,
    sharp_outline,
    rounded_outline,
    circle_filled,
    circle_outline,
    line,
    text,
    image,
    path_fill,
    path_stroke,
    shadow,

    pub const count = @typeInfo(RenderBucket).@"enum".fields.len;
};

/// What `renderProfiled` accumulates. The caller owns it, resets it, and reads it; rendering
/// never allocates, formats or logs.
///
/// **What the numbers are.** `seconds[b]` is the wall time spent dispatching the commands in
/// bucket `b` *in this scene, in this order, with these caches warm*. It is a marginal
/// quantity, not an intrinsic per-kind cost: shared glyph, corner and shadow caches, write
/// locality and branch prediction all make a command cheaper or dearer depending on what
/// surrounds it.
///
/// **What the profile does not cover.** Domain validation is outside every bucket: at a scale
/// other than one it runs before the span starts, and at scale one it does not run as a
/// separate pass at all. A bucket therefore measures drawing, not the checking that precedes
/// it, and `total()` is correspondingly a little under the whole of a `gui_render` section.
///
/// **What the span covers.** Profiling reads the clock twice per command, but a bucket's
/// elapsed time spans the command body and the closing read only: classification and the
/// opening read happen before the span starts, and recording happens after it ends. The
/// closing read is therefore charged to the command, which matters when reading a cheap
/// bucket — a command costing a fraction of a microsecond carries a read of tens of
/// nanoseconds. `counts` is there to size that per bucket.
pub const RenderProfile = struct {
    /// Commands charged to each bucket.
    counts: [RenderBucket.count]u64 = @splat(0),
    /// Seconds spent in each bucket. The closing clock read falls inside the interval; the
    /// opening one does not.
    seconds: [RenderBucket.count]f64 = @splat(0),
    /// Commands dispatched, whether or not they drew anything.
    commands: u64 = 0,
    /// Commands the renderer skipped because their clip was empty. They are dispatched and
    /// charged like any other, because the dispatch is real work even when the drawing is not.
    ///
    /// The clip is tested at the scale the renderer uses, not the logical one: at a scale below
    /// one, a clip a pixel wide scales to nothing and the command is skipped even though its
    /// logical clip is not empty.
    empty_clip: u64 = 0,
    /// Commands whose paint was a gradient rather than a solid colour.
    gradient: u64 = 0,
    /// Commands whose parameters select an anti-aliased route. A sharp rectangle carries an
    /// `aa` flag the sharp path never consults and a zero-radius circle is not drawn at all,
    /// so neither is counted; a path is, because it always goes through the coverage
    /// rasterizer. It counts the route chosen, **not** pixels anti-aliased: a command clipped
    /// to nothing, or a path with no area, is counted and shades nothing.
    antialiased: u64 = 0,
    /// Text commands carrying their own font rather than using the one passed to `render`.
    font_override: u64 = 0,

    pub fn total(self: *const RenderProfile) f64 {
        var sum: f64 = 0;
        for (self.seconds) |v| sum += v;
        return sum;
    }

    fn add(self: *RenderProfile, bucket: RenderBucket, elapsed: f64) void {
        const i = @intFromEnum(bucket);
        self.counts[i] += 1;
        self.seconds[i] += elapsed;
    }
};

/// Whether the renderer will skip this command for want of a clip, at the scale it renders at.
fn skipsOnClip(clip: Rect, scale: f32) bool {
    return if (scale == 1.0) clip.isEmpty() else scaleRect(clip, scale).isEmpty();
}

/// The bucket a command is charged to. Attributes (gradient, anti-aliasing, a font override)
/// are counted separately, because they cut across the buckets rather than partitioning them.
fn classify(cmd: draw_mod.DrawCmd, scale: f32, profile: *RenderProfile) RenderBucket {
    profile.commands += 1;
    switch (cmd) {
        .rect_filled => |c| {
            if (c.paint != .solid) profile.gradient += 1;
            if (c.radius != 0 and c.aa) profile.antialiased += 1;
            if (skipsOnClip(c.clip, scale)) profile.empty_clip += 1;
            return if (c.radius == 0) .sharp_fill else .rounded_fill;
        },
        .rect_outline => |c| {
            if (c.radius != 0 and c.aa) profile.antialiased += 1;
            if (skipsOnClip(c.clip, scale)) profile.empty_clip += 1;
            return if (c.radius == 0) .sharp_outline else .rounded_outline;
        },
        .circle_filled => |c| {
            if (c.aa and c.radius != 0) profile.antialiased += 1;
            if (skipsOnClip(c.clip, scale)) profile.empty_clip += 1;
            return .circle_filled;
        },
        .circle_outline => |c| {
            if (c.aa and c.radius != 0) profile.antialiased += 1;
            if (skipsOnClip(c.clip, scale)) profile.empty_clip += 1;
            return .circle_outline;
        },
        .line => |c| {
            if (skipsOnClip(c.clip, scale)) profile.empty_clip += 1;
            return .line;
        },
        .text => |c| {
            if (c.font != null) profile.font_override += 1;
            if (skipsOnClip(c.clip, scale)) profile.empty_clip += 1;
            return .text;
        },
        .image => |c| {
            if (skipsOnClip(c.clip, scale)) profile.empty_clip += 1;
            return .image;
        },
        .path => |c| {
            if (c.aa) profile.antialiased += 1;
            if (skipsOnClip(c.clip, scale)) profile.empty_clip += 1;
            return if (c.stroke == null) .path_fill else .path_stroke;
        },
        .shadow => |c| {
            if (skipsOnClip(c.clip, scale)) profile.empty_clip += 1;
            return .shadow;
        },
    }
}

/// A clock for `renderProfiled`, injected by the caller.
///
/// It must be a **real** monotonic clock (`platform.getRealTime`, not `platform.getTime`):
/// under a replay the latter is the harness's virtual clock and every bucket would read zero.
/// The GUI does not reach for one itself, because that would make this layer depend on a
/// platform backend — the same reason `core/control/frame_prof.zig` has its caller inject one.
pub const RenderClock = *const fn () f64;

/// Largest `scale` `render` accepts. A coordinate of 2^20 plus an extent of
/// 2^20 is 2^21; times 256 is 2^29, which still fits in i32 after `drawLine`
/// expands the AABB by thickness (`max - min` plus thickness).
pub const MAX_SCALE: f32 = 256.0;

/// True when `scale` is finite and in `(0, MAX_SCALE]`. NaN fails this
/// comparison, so it does not need a separate check.
pub fn scaleWithinDomain(scale: f32) bool {
    return scale > 0.0 and scale <= MAX_SCALE;
}

/// True when every coordinate, extent, and thickness the command will
/// physicalize lies in `geom`'s DrawCmd domain. Path points must also be
/// finite. A path stroke's `width` must be finite and in
/// `(0, path_stroke_width_max]`; `miter_limit` must be finite and `>= 1`.
pub fn cmdWithinDomain(cmd: draw_mod.DrawCmd) bool {
    return switch (cmd) {
        .rect_filled => |c| rectInDomain(c.rect) and rectInDomain(c.clip) and extentInDomain(c.radius) and paintInDomain(c.paint),
        .rect_outline => |c| rectInDomain(c.rect) and rectInDomain(c.clip) and thicknessInDomain(c.thickness) and extentInDomain(c.radius),
        .circle_filled => |c| pointInDomain(c.center) and extentInDomain(c.radius) and rectInDomain(c.clip),
        .circle_outline => |c| pointInDomain(c.center) and extentInDomain(c.radius) and thicknessInDomain(c.thickness) and rectInDomain(c.clip),
        .line => |c| pointInDomain(c.p0) and pointInDomain(c.p1) and rectInDomain(c.clip) and thicknessInDomain(c.thickness),
        .text => |c| pointInDomain(c.pos) and rectInDomain(c.clip),
        .image => |c| rectInDomain(c.rect) and rectInDomain(c.clip),
        .path => |c| pathInDomain(c),
        .shadow => |c| rectInDomain(c.rect) and rectInDomain(c.clip) and
            pointInDomain(c.options.offset) and extentInDomain(c.options.radius) and
            extentInDomain(c.options.blur),
    };
}

fn paintInDomain(paint: Paint) bool {
    return switch (paint) {
        .solid => true,
        .linear => |g| std.math.isFinite(g.start.x) and std.math.isFinite(g.start.y) and
            std.math.isFinite(g.end.x) and std.math.isFinite(g.end.y) and
            coordFloatInDomain(g.start.x) and coordFloatInDomain(g.start.y) and
            coordFloatInDomain(g.end.x) and coordFloatInDomain(g.end.y) and
            (g.start.x != g.end.x or g.start.y != g.end.y),
        .radial => |g| std.math.isFinite(g.center.x) and std.math.isFinite(g.center.y) and
            coordFloatInDomain(g.center.x) and coordFloatInDomain(g.center.y) and
            std.math.isFinite(g.radius) and g.radius > 0 and g.radius <= @as(f32, @floatFromInt(geom.MAX_EXTENT)),
    };
}

fn coordFloatInDomain(v: f32) bool {
    return v >= @as(f32, @floatFromInt(geom.MIN_COORD)) and
        v <= @as(f32, @floatFromInt(geom.MAX_COORD));
}

fn coordInDomain(v: i32) bool {
    return v >= geom.MIN_COORD and v <= geom.MAX_COORD;
}

fn extentInDomain(v: u32) bool {
    return v <= geom.MAX_EXTENT;
}

fn thicknessInDomain(v: u32) bool {
    return v <= geom.MAX_THICKNESS;
}

fn pointInDomain(p: Vec2) bool {
    return coordInDomain(p.x) and coordInDomain(p.y);
}

fn rectInDomain(r: Rect) bool {
    return coordInDomain(r.x) and coordInDomain(r.y) and extentInDomain(r.w) and extentInDomain(r.h);
}

fn pathPointInDomain(p: draw_mod.Vec2f) bool {
    const lo: f32 = @floatFromInt(geom.MIN_COORD);
    const hi: f32 = @floatFromInt(geom.MAX_COORD);
    return std.math.isFinite(p.x) and std.math.isFinite(p.y) and
        p.x >= lo and p.x <= hi and p.y >= lo and p.y <= hi;
}

/// Runs once per DrawCmd per frame on the scaled path; proportional to
/// control-point count, not to target pixel count.
fn pathInDomain(c: @FieldType(draw_mod.DrawCmd, "path")) bool {
    if (!rectInDomain(c.clip)) return false;
    for (c.points) |p| {
        if (!pathPointInDomain(p)) return false;
    }
    if (c.stroke) |st| {
        if (!std.math.isFinite(st.width) or
            !(st.width > 0 and st.width <= draw_mod.path_stroke_width_max) or
            !std.math.isFinite(st.miter_limit) or
            st.miter_limit < 1) return false;
    }
    return true;
}

/// font = default font. Each text cmd may carry a font override that takes priority.
///
/// `scale` converts logical DrawList units to physical target pixels
/// (`1.0` = logical equals physical, fast path). Accepted range is
/// `0 < scale <= MAX_SCALE`. NaN fails the same comparison. A value outside
/// that range panics in every optimisation mode; endpoints are not clamped,
/// because clamping a line or path would change its shape.
///
/// When `scale != 1.0`, each command's coordinates, extents, and thicknesses
/// must lie in `geom.MIN_COORD..=geom.MAX_COORD` / `geom.MAX_EXTENT` /
/// `geom.MAX_THICKNESS`. Path points must also be finite. A path stroke's
/// `width` must be finite and in `(0, path_stroke_width_max]`; `miter_limit`
/// must be finite and `>= 1`. A command outside that domain
/// panics in every optimisation mode. When `scale == 1.0` no physicalization
/// runs, so that domain is not checked.
///
/// `.text` keeps logical coordinates when scale==1.0; when scale!=1.0 it
/// physicalizes pos/clip and passes scale to Font.drawTo.
/// Rasterize a `DrawList` onto `target`.
pub fn render(target: RenderTarget, draw_list: *DrawList, font: Font, scale: f32) void {
    var discard: RenderProfile = .{};
    renderImpl(false, target, draw_list, font, scale, undefined, &discard);
}

/// Rasterize as `render` does, and charge each command to a `RenderBucket`.
///
/// The breakdown costs two clock reads per command, so this is a diagnostic entry point, not
/// a drop-in replacement: an application calls it while investigating and calls `render` the
/// rest of the time. `render` is compiled with the collection branch off, so the ordinary path
/// carries no counter, no clock read and no runtime test.
pub fn renderProfiled(
    target: RenderTarget,
    draw_list: *DrawList,
    font: Font,
    scale: f32,
    clock: RenderClock,
    profile: *RenderProfile,
) void {
    renderImpl(true, target, draw_list, font, scale, clock, profile);
}

fn renderImpl(
    comptime collect: bool,
    target: RenderTarget,
    draw_list: *DrawList,
    font: Font,
    scale: f32,
    clock: RenderClock,
    profile: *RenderProfile,
) void {
    std.debug.assert(target.pixels.len == @as(usize, target.width) * @as(usize, target.height));
    if (!scaleWithinDomain(scale)) {
        std.debug.panic("gui.render: scale {e} is outside the accepted range (0, {d}]", .{ scale, MAX_SCALE });
    }

    if (scale == 1.0) {
        for (draw_list.cmds.items) |cmd| {
            const prof_start = if (collect) blk: {
                const b = classify(cmd, scale, profile);
                break :blk .{ b, clock() };
            } else {};
            switch (cmd) {
                .rect_filled => |c| if (!c.clip.isEmpty()) {
                    if (!paintInDomain(c.paint)) {
                        std.debug.panic("gui.render: rect_filled paint is outside the accepted domain", .{});
                    }
                    if (c.paint == .solid) {
                        if (c.radius == 0) {
                            drawRectFilled(target, c.rect, c.paint.solid, c.clip);
                        } else {
                            drawRoundedFilled(target, draw_list, c.rect, c.paint.solid, c.radius, c.aa, c.clip, 1.0, true);
                        }
                    } else {
                        const plan = makeGradientPlan(c.paint, 1.0);
                        if (c.radius == 0) {
                            drawGradientRect(target, draw_list, c.rect, plan, c.clip, true);
                        } else {
                            drawRoundedGradientFilled(target, draw_list, c.rect, plan, c.radius, c.aa, c.clip, 1.0, true);
                        }
                    }
                },
                .rect_outline => |c| if (!c.clip.isEmpty()) {
                    if (c.radius == 0) {
                        drawRectOutline(target, c.rect, c.color, c.thickness, c.clip);
                    } else {
                        drawRoundedOutline(target, draw_list, c.rect, c.color, c.thickness, c.radius, c.aa, c.clip, 1.0, true);
                    }
                },
                .circle_filled => |c| if (!c.clip.isEmpty() and c.radius != 0) {
                    const r = scaleRadiusUnclamped(c.radius, 1.0);
                    drawRoundedFilledDevice(target, draw_list, circleRect(c.center, r), c.color, r, c.aa, c.clip, 1.0, true);
                },
                .circle_outline => |c| if (!c.clip.isEmpty() and c.radius != 0) {
                    const r = scaleRadiusUnclamped(c.radius, 1.0);
                    drawRoundedOutlineDevice(target, draw_list, circleRect(c.center, r), c.color, c.thickness, r, c.aa, c.clip, 1.0, true);
                },
                .line => |c| if (!c.clip.isEmpty()) drawLine(target, c.p0, c.p1, c.color, c.thickness, c.clip),
                .text => |c| if (!c.clip.isEmpty()) (c.font orelse font).drawTo(target, c.pos, c.text, c.color, c.clip, 1.0),
                .image => |c| if (!c.clip.isEmpty()) drawImage(target, c.rect, c.pixels, c.src_w, c.src_h, c.clip),
                .path => |c| if (!c.clip.isEmpty()) drawPath(target, draw_list, c, 1.0, true),
                .shadow => |c| if (!c.clip.isEmpty()) drawShadow(target, draw_list, c.rect, c.color, c.options, c.clip, 1.0, true),
            }
            if (collect) profile.add(prof_start[0], clock() - prof_start[1]);
        }
        return;
    }

    for (draw_list.cmds.items) |cmd| {
        // The domain check comes first: classification scales the clip to decide whether the
        // renderer will skip the command, and scaling a coordinate that is out of domain
        // overflows before the panic that is supposed to report it.
        if (!cmdWithinDomain(cmd)) {
            std.debug.panic("gui.render: DrawCmd {s} is outside the accepted domain", .{@tagName(cmd)});
        }
        const prof_start = if (collect) blk: {
            const b = classify(cmd, scale, profile);
            break :blk .{ b, clock() };
        } else {};
        switch (cmd) {
            .rect_filled => |c| {
                const phys_clip = scaleRect(c.clip, scale);
                if (!phys_clip.isEmpty()) {
                    if (c.paint == .solid) {
                        if (c.radius == 0) {
                            drawRectFilled(target, scaleRect(c.rect, scale), c.paint.solid, phys_clip);
                        } else {
                            drawRoundedFilled(target, draw_list, scaleRect(c.rect, scale), c.paint.solid, c.radius, c.aa, phys_clip, scale, true);
                        }
                    } else {
                        const plan = makeGradientPlan(c.paint, scale);
                        if (c.radius == 0) {
                            drawGradientRect(target, draw_list, scaleRect(c.rect, scale), plan, phys_clip, true);
                        } else {
                            drawRoundedGradientFilled(target, draw_list, scaleRect(c.rect, scale), plan, c.radius, c.aa, phys_clip, scale, true);
                        }
                    }
                }
            },
            .rect_outline => |c| {
                const phys_clip = scaleRect(c.clip, scale);
                if (!phys_clip.isEmpty()) {
                    if (c.radius == 0) {
                        drawRectOutline(
                            target,
                            scaleRect(c.rect, scale),
                            c.color,
                            scaleThickness(c.thickness, scale),
                            phys_clip,
                        );
                    } else {
                        drawRoundedOutline(
                            target,
                            draw_list,
                            scaleRect(c.rect, scale),
                            c.color,
                            scaleThickness(c.thickness, scale),
                            c.radius,
                            c.aa,
                            phys_clip,
                            scale,
                            true,
                        );
                    }
                }
            },
            .circle_filled => |c| {
                const phys_clip = scaleRect(c.clip, scale);
                if (!phys_clip.isEmpty() and c.radius != 0) {
                    const r = scaleRadiusUnclamped(c.radius, scale);
                    drawRoundedFilledDevice(target, draw_list, circleRect(scalePoint(c.center, scale), r), c.color, r, c.aa, phys_clip, scale, true);
                }
            },
            .circle_outline => |c| {
                const phys_clip = scaleRect(c.clip, scale);
                if (!phys_clip.isEmpty() and c.radius != 0) {
                    const r = scaleRadiusUnclamped(c.radius, scale);
                    drawRoundedOutlineDevice(
                        target,
                        draw_list,
                        circleRect(scalePoint(c.center, scale), r),
                        c.color,
                        scaleThickness(c.thickness, scale),
                        r,
                        c.aa,
                        phys_clip,
                        scale,
                        true,
                    );
                }
            },
            .line => |c| {
                const phys_clip = scaleRect(c.clip, scale);
                if (!phys_clip.isEmpty()) {
                    drawLine(
                        target,
                        scalePoint(c.p0, scale),
                        scalePoint(c.p1, scale),
                        c.color,
                        scaleThickness(c.thickness, scale),
                        phys_clip,
                    );
                }
            },
            .text => |c| {
                const phys_clip = scaleRect(c.clip, scale);
                if (!phys_clip.isEmpty()) {
                    (c.font orelse font).drawTo(
                        target,
                        scalePoint(c.pos, scale),
                        c.text,
                        c.color,
                        phys_clip,
                        scale,
                    );
                }
            },
            .image => |c| {
                const phys_clip = scaleRect(c.clip, scale);
                if (!phys_clip.isEmpty()) {
                    drawImage(target, scaleRect(c.rect, scale), c.pixels, c.src_w, c.src_h, phys_clip);
                }
            },
            .path => |c| {
                const phys_clip = scaleRect(c.clip, scale);
                if (!phys_clip.isEmpty()) {
                    var scaled = c;
                    scaled.clip = phys_clip;
                    drawPath(target, draw_list, scaled, scale, true);
                }
            },
            .shadow => |c| {
                drawShadow(target, draw_list, scaleRect(c.rect, scale), c.color, c.options, scaleRect(c.clip, scale), scale, true);
            },
        }
        if (collect) profile.add(prof_start[0], clock() - prof_start[1]);
    }
}

// ── scale helpers ─────────────────────────────────────────────────────────────

/// Both edges floor: physical.x = floor(x*s), physical.w = max(0, floor((x+w)*s) - physical.x).
/// Under the `render` contract, |logical coord| <= 2^20, extent <= 2^20, and
/// scale <= 256, so |physical| <= 2^29 and `@intFromFloat` stays inside i32.
fn scaleRect(rect: Rect, scale: f32) Rect {
    const x0 = floorI32(@as(f32, @floatFromInt(rect.x)) * scale);
    const y0 = floorI32(@as(f32, @floatFromInt(rect.y)) * scale);
    const x1 = floorI32(@as(f32, @floatFromInt(rect.x + @as(i32, @intCast(rect.w)))) * scale);
    const y1 = floorI32(@as(f32, @floatFromInt(rect.y + @as(i32, @intCast(rect.h)))) * scale);
    return .{
        .x = x0,
        .y = y0,
        .w = if (x1 > x0) @intCast(x1 - x0) else 0,
        .h = if (y1 > y0) @intCast(y1 - y0) else 0,
    };
}

/// Under the `render` contract, |logical coord| <= 2^20 and scale <= 256, so
/// |physical| <= 2^28 and `@intFromFloat` stays inside i32.
fn scalePoint(point: Vec2, scale: f32) Vec2 {
    return .{
        .x = floorI32(@as(f32, @floatFromInt(point.x)) * scale),
        .y = floorI32(@as(f32, @floatFromInt(point.y)) * scale),
    };
}

/// Under the `render` contract, thickness <= 4096 and scale <= 256, so the
/// rounded product is at most 2^20 and fits in u32.
fn scaleThickness(thickness: u32, scale: f32) u32 {
    const t = @round(@as(f32, @floatFromInt(thickness)) * scale);
    if (t < 1.0) return 1;
    return @intFromFloat(t);
}

fn scaleBlurUnclamped(blur: u32, scale: f32) u32 {
    if (blur == 0) return 0;
    const scaled = @round(@as(f32, @floatFromInt(blur)) * scale);
    if (scaled < 1.0) return 1;
    return @intFromFloat(scaled);
}

/// Caller guarantees `v` is finite and inside i32. The `render` contract
/// implies `|v| <= 2^29`.
fn floorI32(v: f32) i32 {
    return @intFromFloat(@floor(v));
}

const LinearPlan = struct {
    start_color: Color,
    end_color: Color,
    base_q8: i64,
    step_x_q8: i64,
    step_y_q8: i64,
    vertical: bool,
};

const RadialPlan = struct {
    inner_color: Color,
    outer_color: Color,
    center: draw_mod.Vec2f,
    inv_radius_squared: f32,
};

const GradientPlan = union(enum) {
    linear: LinearPlan,
    radial: RadialPlan,
};

fn makeGradientPlan(paint: Paint, scale: f32) GradientPlan {
    return switch (paint) {
        .solid => unreachable,
        .linear => |g| {
            const start = draw_mod.Vec2f{ .x = g.start.x * scale, .y = g.start.y * scale };
            const end = draw_mod.Vec2f{ .x = g.end.x * scale, .y = g.end.y * scale };
            const dx = end.x - start.x;
            const dy = end.y - start.y;
            const inv_length_squared = 1.0 / (dx * dx + dy * dy);
            const x_step = fixedQ8(dx * inv_length_squared * 255.0);
            const y_step = fixedQ8(dy * inv_length_squared * 255.0);
            return .{ .linear = .{
                .start_color = g.start_color,
                .end_color = g.end_color,
                .base_q8 = fixedQ8(-start.x * dx * inv_length_squared * 255.0 - start.y * dy * inv_length_squared * 255.0),
                .step_x_q8 = x_step,
                .step_y_q8 = y_step,
                .vertical = dx == 0.0,
            } };
        },
        .radial => |g| {
            const radius = g.radius * scale;
            return .{ .radial = .{
                .inner_color = g.inner_color,
                .outer_color = g.outer_color,
                .center = .{ .x = g.center.x * scale, .y = g.center.y * scale },
                .inv_radius_squared = 1.0 / (radius * radius),
            } };
        },
    };
}

fn fixedQ8(value: f32) i64 {
    const bounded = std.math.clamp(value * 256.0, -9.0e15, 9.0e15);
    return @intFromFloat(@round(bounded));
}

inline fn gradientCoefficient(q8: i64) u8 {
    if (q8 <= 0) return 0;
    if (q8 >= 255 * 256) return 255;
    return @intCast((q8 + 128) >> 8);
}

fn gradientIsOpaque(plan: GradientPlan) bool {
    return switch (plan) {
        .linear => |p| p.start_color.a == 255 and p.end_color.a == 255,
        .radial => |p| p.inner_color.a == 255 and p.outer_color.a == 255,
    };
}

fn gradientColors4(start: u32, end: u32, t: @Vector(4, u8), comptime use_simd: bool) @Vector(16, u8) {
    if (comptime use_simd) return pixelops.lerpColor4(@bitCast([4]u32{ start, start, start, start }), @bitCast([4]u32{ end, end, end, end }), t);
    var out: [4]u32 = undefined;
    for (0..4) |i| out[i] = pixelops.lerpColor(start, end, t[i]);
    return @bitCast(out);
}

fn storeGradient4(dst: *[4]u32, colors: @Vector(16, u8), is_opaque: bool, comptime use_simd: bool) void {
    if (comptime use_simd) {
        if (is_opaque) {
            dst.* = @bitCast(colors);
        } else {
            dst.* = @bitCast(pixelops.srcOverOpaque4(@bitCast(dst.*), colors));
        }
        return;
    }
    const scalar: [4]u32 = @bitCast(colors);
    for (0..4) |i| {
        dst[i] = if (is_opaque) scalar[i] else pixelops.srcOverOpaque(dst[i], scalar[i]);
    }
}

fn buildLinearColumns(draw_list: *DrawList, bounds: Rect, plan: LinearPlan) []i64 {
    const columns = draw_list.ensureLinearGradientColumns(bounds.w);
    var q = plan.base_q8 + @as(i64, bounds.x) * plan.step_x_q8;
    for (columns) |*column| {
        column.* = q;
        q += plan.step_x_q8;
    }
    return columns;
}

/// Runs over every gradient pixel, every frame. The command-level plan hoists
/// reciprocal setup; the row loop uses four-pixel interpolation and a scalar tail.
fn drawGradientRect(target: RenderTarget, draw_list: *DrawList, rect: Rect, plan: GradientPlan, clip: Rect, comptime use_simd: bool) void {
    const bounds = clipRect(rect, clip, target);
    if (bounds.isEmpty()) return;
    switch (plan) {
        .linear => |linear| drawLinearRect(target, draw_list, bounds, linear, comptime use_simd),
        .radial => |radial| drawRadialRect(target, draw_list, bounds, radial, comptime use_simd),
    }
}

fn drawLinearRect(target: RenderTarget, draw_list: *DrawList, bounds: Rect, plan: LinearPlan, comptime use_simd: bool) void {
    const is_opaque = plan.start_color.a == 255 and plan.end_color.a == 255;
    const start_u32: u32 = @bitCast(plan.start_color);
    const end_u32: u32 = @bitCast(plan.end_color);
    const x0: u32 = @intCast(bounds.x);
    const y0: u32 = @intCast(bounds.y);
    var row: u32 = 0;
    if (plan.vertical) {
        while (row < bounds.h) : (row += 1) {
            const t = gradientCoefficient(plan.base_q8 + @as(i64, y0 + row) * plan.step_y_q8);
            const color = pixelops.lerpColor(start_u32, end_u32, t);
            const base = (@as(usize, y0) + row) * target.width + x0;
            if (is_opaque) {
                pixelops.fill32(target.pixels[base..][0..bounds.w], color);
                continue;
            }
            var x: u32 = 0;
            while (x + 4 <= bounds.w) : (x += 4) {
                const dst: *[4]u32 = target.pixels[base + x ..][0..4];
                const colors = @as(@Vector(16, u8), @bitCast([4]u32{ color, color, color, color }));
                storeGradient4(dst, colors, false, comptime use_simd);
            }
            while (x < bounds.w) : (x += 1) {
                target.pixels[base + x] = pixelops.srcOverOpaque(target.pixels[base + x], color);
            }
        }
        return;
    }

    const columns = buildLinearColumns(draw_list, bounds, plan);
    while (row < bounds.h) : (row += 1) {
        const row_q8 = @as(i64, y0 + row) * plan.step_y_q8;
        const base = (@as(usize, y0) + row) * target.width + x0;
        var x: u32 = 0;
        while (x + 4 <= bounds.w) : (x += 4) {
            const t: @Vector(4, u8) = .{
                gradientCoefficient(columns[x] + row_q8),
                gradientCoefficient(columns[x + 1] + row_q8),
                gradientCoefficient(columns[x + 2] + row_q8),
                gradientCoefficient(columns[x + 3] + row_q8),
            };
            const colors = gradientColors4(start_u32, end_u32, t, comptime use_simd);
            storeGradient4(target.pixels[base + x ..][0..4], colors, is_opaque, comptime use_simd);
        }
        while (x < bounds.w) : (x += 1) {
            const t = gradientCoefficient(columns[x] + row_q8);
            const color = pixelops.lerpColor(start_u32, end_u32, t);
            target.pixels[base + x] = if (is_opaque) color else pixelops.srcOverOpaque(target.pixels[base + x], color);
        }
    }
}

fn ensureRadialGradientLut(draw_list: *DrawList) []const u8 {
    const lut = draw_list.ensureRadialGradientLut();
    if (!draw_list.radial_gradient_lut_ready) {
        for (lut, 0..) |*entry, i| {
            const normalized_squared: f32 = @as(f32, @floatFromInt(i)) / 1023.0;
            entry.* = @intFromFloat(@round(std.math.sqrt(normalized_squared) * 255.0));
        }
        draw_list.radial_gradient_lut_ready = true;
    }
    return lut;
}

inline fn radialCoefficient(lut: []const u8, squared_distance: f32, inv_radius_squared: f32) u8 {
    const normalized = @min(1.0, squared_distance * inv_radius_squared);
    const index: usize = @intFromFloat(normalized * 1023.0);
    return lut[index];
}

fn drawRadialRect(target: RenderTarget, draw_list: *DrawList, bounds: Rect, plan: RadialPlan, comptime use_simd: bool) void {
    const lut = ensureRadialGradientLut(draw_list);
    const is_opaque = plan.inner_color.a == 255 and plan.outer_color.a == 255;
    const inner_u32: u32 = @bitCast(plan.inner_color);
    const outer_u32: u32 = @bitCast(plan.outer_color);
    const x0: f32 = @floatFromInt(bounds.x);
    var row: u32 = 0;
    while (row < bounds.h) : (row += 1) {
        var dx = x0 - plan.center.x;
        const dy = @as(f32, @floatFromInt(@as(i32, bounds.y) + @as(i32, @intCast(row)))) - plan.center.y;
        var squared_distance = dx * dx + dy * dy;
        var delta = 2.0 * dx + 1.0;
        const base = (@as(usize, @intCast(bounds.y)) + row) * target.width + @as(usize, @intCast(bounds.x));
        var x: u32 = 0;
        while (x + 4 <= bounds.w) : (x += 4) {
            var t: [4]u8 = undefined;
            inline for (0..4) |lane| {
                t[lane] = radialCoefficient(lut, squared_distance, plan.inv_radius_squared);
                squared_distance += delta;
                delta += 2.0;
            }
            const colors = gradientColors4(inner_u32, outer_u32, t, comptime use_simd);
            storeGradient4(target.pixels[base + x ..][0..4], colors, is_opaque, comptime use_simd);
            dx += 4.0;
        }
        while (x < bounds.w) : (x += 1) {
            const t = radialCoefficient(lut, squared_distance, plan.inv_radius_squared);
            const color = pixelops.lerpColor(inner_u32, outer_u32, t);
            target.pixels[base + x] = if (is_opaque) color else pixelops.srcOverOpaque(target.pixels[base + x], color);
            squared_distance += delta;
            delta += 2.0;
            dx += 1.0;
        }
    }
}

// ── pixel helpers ─────────────────────────────────────────────────────────────

fn blendPixel(dst: u32, src: Color) u32 {
    const dst_col: Color = @bitCast(dst);
    return @bitCast(Color.blend(dst_col, src));
}

/// Intersect rect, clip, and target on three axes and return the drawable region.
fn clipRect(rect: Rect, clip: Rect, target: RenderTarget) Rect {
    const target_rect = Rect{ .x = 0, .y = 0, .w = target.width, .h = target.height };
    return Rect.intersect(Rect.intersect(rect, clip), target_rect);
}

const ShadowRegion = enum { corner, horizontal_edge, vertical_edge, center };

fn shadowCoverage(mask: shadow_mask.Mask, region: ShadowRegion, source_x: u32, source_y: u32, mirror_x: bool, mirror_y: bool, x: u32, y: u32) u8 {
    return switch (region) {
        .center => 255,
        .horizontal_edge => mask.edge[if (mirror_y) mask.extent - 1 - (source_y + y) else source_y + y],
        .vertical_edge => mask.edge[if (mirror_x) mask.extent - 1 - (source_x + x) else source_x + x],
        .corner => mask.corner[
            @as(usize, if (mirror_y) mask.extent - 1 - (source_y + y) else source_y + y) * mask.extent +
                (if (mirror_x) mask.extent - 1 - (source_x + x) else source_x + x)
        ],
    };
}

/// Composite one disjoint nine-slice region. All clipping and source coordinates are
/// resolved before the row loop; the loop only indexes retained coverage and blends pixels.
fn blitShadowRegion(
    target: RenderTarget,
    draw_list: *DrawList,
    dst: Rect,
    clip: Rect,
    mask: shadow_mask.Mask,
    color: Color,
    region: ShadowRegion,
    source_x: u32,
    source_y: u32,
    mirror_x: bool,
    mirror_y: bool,
    comptime use_simd: bool,
) void {
    const bounds = clipRect(dst, clip, target);
    if (bounds.isEmpty() or color.a == 0) return;
    draw_list.shadow_masks.addBlitPixels(@as(usize, bounds.w) * bounds.h);

    const src_u32: u32 = @bitCast(color);
    const src4 = [4]u32{ src_u32, src_u32, src_u32, src_u32 };
    const local_x0: u32 = @intCast(bounds.x - dst.x);
    const local_y0: u32 = @intCast(bounds.y - dst.y);
    const dst_x: u32 = @intCast(bounds.x);
    const dst_y: u32 = @intCast(bounds.y);

    var row: u32 = 0;
    while (row < bounds.h) : (row += 1) {
        const dst_base = (@as(usize, dst_y) + row) * target.width + dst_x;
        var x: u32 = 0;
        while (x + 4 <= bounds.w) : (x += 4) {
            var coverage: [4]u8 = undefined;
            inline for (0..4) |lane| {
                coverage[lane] = shadowCoverage(
                    mask,
                    region,
                    source_x,
                    source_y,
                    mirror_x,
                    mirror_y,
                    local_x0 + x + @as(u32, @intCast(lane)),
                    local_y0 + row,
                );
            }
            const cov4: @Vector(4, u8) = coverage;
            if (@reduce(.Or, cov4) != 0) {
                const dst_chunk: *[4]u32 = target.pixels[dst_base + x ..][0..4];
                if (comptime use_simd) {
                    dst_chunk.* = @bitCast(pixelops.srcOverCoverage4(@bitCast(dst_chunk.*), @bitCast(src4), cov4));
                } else {
                    for (0..4) |lane| {
                        if (coverage[lane] != 0) {
                            dst_chunk[lane] = pixelops.srcOverCoverage(dst_chunk[lane], src_u32, coverage[lane]);
                        }
                    }
                }
            }
        }
        while (x < bounds.w) : (x += 1) {
            const coverage = shadowCoverage(mask, region, source_x, source_y, mirror_x, mirror_y, local_x0 + x, local_y0 + row);
            if (coverage != 0) {
                target.pixels[dst_base + x] = pixelops.srcOverCoverage(target.pixels[dst_base + x], src_u32, coverage);
            }
        }
    }
}

/// The nine-slice layout of one shadow, derived from its outer rectangle in
/// device pixels: `outer` inset by `slice` on all four sides is `center`, and the
/// corner and edge slices cover the ring between them. Deriving both in one place
/// keeps every reader agreeing on where the slices fall.
const ShadowGeometry = struct {
    /// Corner and edge slice size. Zero means the shadow is too small to blit.
    slice: u32,
    /// The uniform interior. Empty when the outer rectangle is at most two slices
    /// wide or tall.
    center: Rect,

    fn init(outer: Rect, extent: u32) ShadowGeometry {
        const slice = @min(extent, @min(outer.w / 2, outer.h / 2));
        return .{
            .slice = slice,
            .center = .{
                .x = outer.x + @as(i32, @intCast(slice)),
                .y = outer.y + @as(i32, @intCast(slice)),
                .w = outer.w - slice * 2,
                .h = outer.h - slice * 2,
            },
        };
    }
};

/// `rect` and `clip` arrive in device pixels: like the other rectangle commands,
/// the caller physicalizes them. `radius`, `blur` and `offset` live in the options
/// rather than in the command's geometry, so they are physicalized here.
fn drawShadow(
    target: RenderTarget,
    draw_list: *DrawList,
    rect: Rect,
    color: Color,
    options: draw_mod.ShadowOptions,
    clip: Rect,
    scale: f32,
    comptime use_simd: bool,
) void {
    if (rect.isEmpty() or clip.isEmpty() or color.a == 0) return;
    const radius = if (options.radius == 0) 0 else scaleRadiusUnclamped(options.radius, scale);
    const blur = scaleBlurUnclamped(options.blur, scale);
    const offset = scalePoint(options.offset, scale);
    const blur_i: i32 = @intCast(blur);
    const outer = Rect{
        .x = rect.x + offset.x - blur_i,
        .y = rect.y + offset.y - blur_i,
        .w = rect.w + blur * 2,
        .h = rect.h + blur * 2,
    };
    const visible = clipRect(outer, clip, target);
    if (visible.isEmpty()) return;

    const key = shadow_mask.ShadowMaskKey.init(radius, blur, scale);
    const mask = draw_list.shadow_masks.getOrCreate(draw_list.alloc, key) catch |err| switch (err) {
        error.KeyTooLarge => @panic("gui shadow mask key exceeds bounded cache"),
        error.OutOfMemory => @panic("gui shadow mask cache: OOM"),
    };
    const geo = ShadowGeometry.init(outer, mask.extent);
    const slice = geo.slice;
    if (slice == 0) return;
    const center_w = geo.center.w;
    const center_h = geo.center.h;
    const far_x = mask.extent - slice;
    const far_y = mask.extent - slice;
    const horizontal_a = center_w / 2;
    const horizontal_b = center_w - horizontal_a;
    const vertical_a = center_h / 2;
    const vertical_b = center_h - vertical_a;

    blitShadowRegion(target, draw_list, .{ .x = outer.x, .y = outer.y, .w = slice, .h = slice }, clip, mask, color, .corner, 0, 0, false, false, use_simd);
    blitShadowRegion(target, draw_list, .{ .x = outer.x + @as(i32, @intCast(outer.w - slice)), .y = outer.y, .w = slice, .h = slice }, clip, mask, color, .corner, far_x, 0, true, false, use_simd);
    blitShadowRegion(target, draw_list, .{ .x = outer.x, .y = outer.y + @as(i32, @intCast(outer.h - slice)), .w = slice, .h = slice }, clip, mask, color, .corner, 0, far_y, false, true, use_simd);
    blitShadowRegion(target, draw_list, .{ .x = outer.x + @as(i32, @intCast(outer.w - slice)), .y = outer.y + @as(i32, @intCast(outer.h - slice)), .w = slice, .h = slice }, clip, mask, color, .corner, far_x, far_y, true, true, use_simd);

    if (center_w != 0) {
        if (horizontal_a != 0) {
            blitShadowRegion(target, draw_list, .{ .x = outer.x + @as(i32, @intCast(slice)), .y = outer.y, .w = horizontal_a, .h = slice }, clip, mask, color, .horizontal_edge, 0, 0, false, false, use_simd);
            blitShadowRegion(target, draw_list, .{ .x = outer.x + @as(i32, @intCast(slice)), .y = outer.y + @as(i32, @intCast(outer.h - slice)), .w = horizontal_a, .h = slice }, clip, mask, color, .horizontal_edge, 0, far_y, false, true, use_simd);
        }
        blitShadowRegion(target, draw_list, .{ .x = outer.x + @as(i32, @intCast(slice + horizontal_a)), .y = outer.y, .w = horizontal_b, .h = slice }, clip, mask, color, .horizontal_edge, 0, 0, false, false, use_simd);
        blitShadowRegion(target, draw_list, .{ .x = outer.x + @as(i32, @intCast(slice + horizontal_a)), .y = outer.y + @as(i32, @intCast(outer.h - slice)), .w = horizontal_b, .h = slice }, clip, mask, color, .horizontal_edge, 0, far_y, false, true, use_simd);
    }
    if (center_h != 0) {
        if (vertical_a != 0) {
            blitShadowRegion(target, draw_list, .{ .x = outer.x, .y = outer.y + @as(i32, @intCast(slice)), .w = slice, .h = vertical_a }, clip, mask, color, .vertical_edge, 0, 0, false, false, use_simd);
            blitShadowRegion(target, draw_list, .{ .x = outer.x + @as(i32, @intCast(outer.w - slice)), .y = outer.y + @as(i32, @intCast(slice)), .w = slice, .h = vertical_a }, clip, mask, color, .vertical_edge, far_x, 0, true, false, use_simd);
        }
        blitShadowRegion(target, draw_list, .{ .x = outer.x, .y = outer.y + @as(i32, @intCast(slice + vertical_a)), .w = slice, .h = vertical_b }, clip, mask, color, .vertical_edge, 0, 0, false, false, use_simd);
        blitShadowRegion(target, draw_list, .{ .x = outer.x + @as(i32, @intCast(outer.w - slice)), .y = outer.y + @as(i32, @intCast(slice + vertical_a)), .w = slice, .h = vertical_b }, clip, mask, color, .vertical_edge, far_x, 0, true, false, use_simd);
    }
    if (center_w != 0 and center_h != 0) {
        blitShadowRegion(target, draw_list, geo.center, clip, mask, color, .center, 0, 0, false, false, use_simd);
    }
}

// ── draw primitives ───────────────────────────────────────────────────────────

/// Hot path that runs every frame (full GUI redraw). Clip intersection is outside the loop (clipRect).
/// Opaque colors (most GUI fills) go through `pixelops.fillRect32`, which fills the first row
/// and replicates it (`Color.blend(dst, a=255 src) == src`, so bit-identical to the blend path).
fn drawRectFilled(target: RenderTarget, rect: Rect, col: Color, clip: Rect) void {
    const bounds = clipRect(rect, clip, target);
    if (bounds.isEmpty()) return;
    const x0: u32 = @intCast(bounds.x);
    const y0: u32 = @intCast(bounds.y);
    const x1: u32 = x0 + bounds.w;
    const y1: u32 = y0 + bounds.h;
    if (col.a == 255) {
        pixelops.fillRect32(target.pixels, target.width, x0, y0, bounds.w, bounds.h, @bitCast(col));
        return;
    }
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = target.pixels[y * target.width .. y * target.width + target.width];
        var x = x0;
        while (x < x1) : (x += 1) {
            row[x] = blendPixel(row[x], col);
        }
    }
}

fn drawRectOutline(target: RenderTarget, rect: Rect, col: Color, thickness: u32, clip: Rect) void {
    const t = if (thickness == 0) @as(u32, 1) else thickness;
    const x = rect.x;
    const y = rect.y;
    const w = rect.w;
    const h = rect.h;

    // Top
    const top_h = @min(t, h);
    drawRectFilled(target, .{ .x = x, .y = y, .w = w, .h = top_h }, col, clip);

    if (h > top_h) {
        // Bottom
        const bot_h = @min(t, h - top_h);
        const bot_y: i32 = y + @as(i32, @intCast(h - bot_h));
        drawRectFilled(target, .{ .x = x, .y = bot_y, .w = w, .h = bot_h }, col, clip);

        // Middle: left and right sides only (clamp so left and right do not overlap)
        const mid_y: i32 = y + @as(i32, @intCast(top_h));
        const mid_h = h - top_h - bot_h;
        if (mid_h > 0) {
            const left_w = @min(t, w);
            drawRectFilled(target, .{ .x = x, .y = mid_y, .w = left_w, .h = mid_h }, col, clip);
            if (w > t) {
                // Keep the right band from overlapping past the left band's right edge
                // (when t < w < 2t, overlapping left/right bands would double-blend a translucent outline)
                const left_end: i32 = x + @as(i32, @intCast(left_w));
                const right_start: i32 = @max(x + @as(i32, @intCast(w - t)), left_end);
                const right_end: i32 = x + @as(i32, @intCast(w));
                if (right_end > right_start) {
                    const right_w: u32 = @intCast(right_end - right_start);
                    drawRectFilled(target, .{ .x = right_start, .y = mid_y, .w = right_w, .h = mid_h }, col, clip);
                }
            }
        }
    }
}

const CornerOrientation = enum { top_left, top_right, bottom_left, bottom_right };

const CachedMask = struct {
    coverage: []const u8,
    radius: u32,
};

fn scaleRadiusUnclamped(radius: u32, scale: f32) u32 {
    std.debug.assert(radius != 0);
    const scaled = @round(@as(f32, @floatFromInt(radius)) * scale);
    if (scaled < 1.0) return 1;
    return @intFromFloat(scaled);
}

fn clampedDeviceRadius(rect: Rect, radius: u32, scale: f32) u32 {
    if (radius == 0) return 0;
    return @min(scaleRadiusUnclamped(radius, scale), @min(rect.w, rect.h) / 2);
}

fn circleRect(center: Vec2, radius: u32) Rect {
    const ri: i32 = @intCast(radius);
    return .{
        .x = center.x - ri,
        .y = center.y - ri,
        .w = radius * 2,
        .h = radius * 2,
    };
}

fn cornerRect(rect: Rect, radius: u32, orientation: CornerOrientation) Rect {
    const right = rect.x + @as(i32, @intCast(rect.w - radius));
    const bottom = rect.y + @as(i32, @intCast(rect.h - radius));
    return switch (orientation) {
        .top_left => .{ .x = rect.x, .y = rect.y, .w = radius, .h = radius },
        .top_right => .{ .x = right, .y = rect.y, .w = radius, .h = radius },
        .bottom_left => .{ .x = rect.x, .y = bottom, .w = radius, .h = radius },
        .bottom_right => .{ .x = right, .y = bottom, .w = radius, .h = radius },
    };
}

fn getCornerMask(draw_list: *DrawList, radius: u32, scale: f32) ?CachedMask {
    const key = corner_mask.CornerMaskKey.init(radius, scale);
    if (draw_list.corner_masks.lookup(key)) |coverage| {
        return .{ .coverage = coverage, .radius = radius };
    }
    if (!corner_mask.Cache.cacheable(radius)) return null;

    const len = corner_mask.Cache.payloadBytes(radius).?;
    const owned = draw_list.alloc.alloc(u8, len) catch
        @panic("gui rounded mask: OOM");
    errdefer draw_list.alloc.free(owned);
    const max_pixels = draw_mod.path_scratch_limit_bytes / draw_mod.path_scratch_bytes_per_pixel;
    const band_h: u32 = @max(1, @as(u32, @intCast(max_pixels / radius)));
    var y: u32 = 0;
    while (y < radius) {
        const h = @min(band_h, radius - y);
        const pixels = @as(usize, radius) * h;
        draw_list.ensurePathScratch(pixels);
        corner_mask.rasterizeBand(
            radius,
            0,
            y,
            radius,
            h,
            draw_list.path_area,
            draw_list.path_cover,
            draw_list.path_coverage,
        );
        @memcpy(owned[@as(usize, y) * radius ..][0..pixels], draw_list.path_coverage[0..pixels]);
        y += h;
    }
    const coverage = draw_list.corner_masks.insertOwned(draw_list.alloc, key, owned) catch
        @panic("gui rounded mask cache: OOM");
    return .{ .coverage = coverage, .radius = radius };
}

fn sourceX(orientation: CornerOrientation, radius: u32, local_x: u32) u32 {
    return switch (orientation) {
        .top_left, .bottom_left => local_x,
        .top_right, .bottom_right => radius - 1 - local_x,
    };
}

fn sourceY(orientation: CornerOrientation, radius: u32, local_y: u32) u32 {
    return switch (orientation) {
        .top_left, .top_right => local_y,
        .bottom_left, .bottom_right => radius - 1 - local_y,
    };
}

fn finalCoverage(
    outer: CachedMask,
    inner: ?CachedMask,
    inset: u32,
    sx: u32,
    sy: u32,
    aa: bool,
) u8 {
    var coverage = outer.coverage[@as(usize, sy) * outer.radius + sx];
    if (inner) |mask| {
        if (sx >= inset and sy >= inset and sx - inset < mask.radius and sy - inset < mask.radius) {
            const inner_coverage = mask.coverage[@as(usize, sy - inset) * mask.radius + (sx - inset)];
            coverage -|= inner_coverage;
        }
    }
    if (!aa) coverage = if (coverage >= 128) 255 else 0;
    return coverage;
}

/// Hot path: composites at most four `radius * radius` corner masks per
/// rounded primitive per frame. Clip and source orientation are resolved per
/// row; four adjacent coverages use `srcOverCoverage4` with a scalar tail.
fn blitCachedCorner(
    target: RenderTarget,
    draw_list: *DrawList,
    dst: Rect,
    clip: Rect,
    orientation: CornerOrientation,
    outer: CachedMask,
    inner: ?CachedMask,
    inset: u32,
    aa: bool,
    col: Color,
    comptime use_simd: bool,
) void {
    const bounds = clipRect(dst, clip, target);
    if (bounds.isEmpty()) return;
    draw_list.corner_masks.addCoveragePixels(@as(usize, bounds.w) * bounds.h);

    const src_u32: u32 = @bitCast(col);
    const src4 = [4]u32{ src_u32, src_u32, src_u32, src_u32 };
    const dst_x: u32 = @intCast(bounds.x);
    const dst_y: u32 = @intCast(bounds.y);
    const local_x0: u32 = @intCast(bounds.x - dst.x);
    const local_y0: u32 = @intCast(bounds.y - dst.y);

    var row: u32 = 0;
    while (row < bounds.h) : (row += 1) {
        const sy = sourceY(orientation, outer.radius, local_y0 + row);
        const dst_base = (dst_y + row) * target.width + dst_x;
        var x: u32 = 0;
        if (col.a == 255) {
            while (x < bounds.w) {
                const sx = sourceX(orientation, outer.radius, local_x0 + x);
                const coverage = finalCoverage(outer, inner, inset, sx, sy, aa);
                if (coverage == 0) {
                    x += 1;
                    continue;
                }
                if (coverage == 255) {
                    var run = x + 1;
                    while (run < bounds.w) : (run += 1) {
                        const run_sx = sourceX(orientation, outer.radius, local_x0 + run);
                        if (finalCoverage(outer, inner, inset, run_sx, sy, aa) != 255) break;
                    }
                    pixelops.fill32(target.pixels[dst_base + x ..][0 .. run - x], src_u32);
                    x = run;
                    continue;
                }
                if (comptime use_simd) {
                    if (x + 4 <= bounds.w) {
                        var cov: [4]u8 = undefined;
                        inline for (0..4) |lane| {
                            const lane_sx = sourceX(orientation, outer.radius, local_x0 + x + @as(u32, @intCast(lane)));
                            cov[lane] = finalCoverage(outer, inner, inset, lane_sx, sy, aa);
                        }
                        const cov4: @Vector(4, u8) = cov;
                        const dst_chunk: *[4]u32 = target.pixels[dst_base + x ..][0..4];
                        dst_chunk.* = @bitCast(pixelops.srcOverCoverage4(@bitCast(dst_chunk.*), @bitCast(src4), cov4));
                        x += 4;
                        continue;
                    }
                }
                target.pixels[dst_base + x] = pixelops.srcOverCoverage(target.pixels[dst_base + x], src_u32, coverage);
                x += 1;
            }
            continue;
        }
        if (comptime use_simd) {
            while (x + 4 <= bounds.w) : (x += 4) {
                var cov: [4]u8 = undefined;
                inline for (0..4) |lane| {
                    const sx = sourceX(orientation, outer.radius, local_x0 + x + @as(u32, @intCast(lane)));
                    cov[lane] = finalCoverage(outer, inner, inset, sx, sy, aa);
                }
                const cov4: @Vector(4, u8) = cov;
                if (@reduce(.Or, cov4) == 0) continue;
                const dst_chunk: *[4]u32 = target.pixels[dst_base + x ..][0..4];
                dst_chunk.* = @bitCast(pixelops.srcOverCoverage4(@bitCast(dst_chunk.*), @bitCast(src4), cov4));
            }
        }
        while (x < bounds.w) : (x += 1) {
            const sx = sourceX(orientation, outer.radius, local_x0 + x);
            const coverage = finalCoverage(outer, inner, inset, sx, sy, aa);
            if (coverage == 0) continue;
            target.pixels[dst_base + x] = pixelops.srcOverCoverage(target.pixels[dst_base + x], src_u32, coverage);
        }
    }
}

fn drawCornerSet(
    target: RenderTarget,
    draw_list: *DrawList,
    rect: Rect,
    radius: u32,
    inner_radius: u32,
    inset: u32,
    aa: bool,
    col: Color,
    clip: Rect,
    scale: f32,
    comptime use_simd: bool,
) void {
    if (getCornerMask(draw_list, radius, scale)) |outer_mask| {
        const inner = if (inner_radius != 0) getCornerMask(draw_list, inner_radius, scale) else null;
        inline for (std.meta.tags(CornerOrientation)) |orientation| {
            blitCachedCorner(
                target,
                draw_list,
                cornerRect(rect, radius, orientation),
                clip,
                orientation,
                outer_mask,
                inner,
                inset,
                aa,
                col,
                use_simd,
            );
        }
        return;
    }
    for (std.meta.tags(CornerOrientation)) |orientation| {
        blitGeneratedCorner(
            target,
            draw_list,
            cornerRect(rect, radius, orientation),
            clip,
            orientation,
            radius,
            inner_radius,
            inset,
            aa,
            col,
            use_simd,
        );
    }
}

fn drawRoundedFilled(
    target: RenderTarget,
    draw_list: *DrawList,
    rect: Rect,
    col: Color,
    logical_radius: u32,
    aa: bool,
    clip: Rect,
    scale: f32,
    comptime use_simd: bool,
) void {
    const radius = clampedDeviceRadius(rect, logical_radius, scale);
    if (radius == 0) return drawRectFilled(target, rect, col, clip);
    drawRoundedFilledDevice(target, draw_list, rect, col, radius, aa, clip, scale, use_simd);
}

fn drawRoundedFilledDevice(
    target: RenderTarget,
    draw_list: *DrawList,
    rect: Rect,
    col: Color,
    radius: u32,
    aa: bool,
    clip: Rect,
    scale: f32,
    comptime use_simd: bool,
) void {
    if (rect.w == 0 or rect.h == 0 or radius == 0) return;
    const center_w = rect.w - radius * 2;
    drawRectFilled(target, .{
        .x = rect.x + @as(i32, @intCast(radius)),
        .y = rect.y,
        .w = center_w,
        .h = rect.h,
    }, col, clip);
    const middle_h = rect.h - radius * 2;
    if (middle_h != 0) {
        const middle_y = rect.y + @as(i32, @intCast(radius));
        drawRectFilled(target, .{ .x = rect.x, .y = middle_y, .w = radius, .h = middle_h }, col, clip);
        drawRectFilled(target, .{
            .x = rect.x + @as(i32, @intCast(rect.w - radius)),
            .y = middle_y,
            .w = radius,
            .h = middle_h,
        }, col, clip);
    }
    drawCornerSet(target, draw_list, rect, radius, 0, 0, aa, col, clip, scale, use_simd);
}

fn gradientColorAt(draw_list: *DrawList, plan: GradientPlan, x: i32, y: i32) u32 {
    return switch (plan) {
        .linear => |p| {
            const q8 = p.base_q8 + @as(i64, x) * p.step_x_q8 + @as(i64, y) * p.step_y_q8;
            return pixelops.lerpColor(@bitCast(p.start_color), @bitCast(p.end_color), gradientCoefficient(q8));
        },
        .radial => |p| {
            const lut = ensureRadialGradientLut(draw_list);
            const dx = @as(f32, @floatFromInt(x)) - p.center.x;
            const dy = @as(f32, @floatFromInt(y)) - p.center.y;
            const t = radialCoefficient(lut, dx * dx + dy * dy, p.inv_radius_squared);
            return pixelops.lerpColor(@bitCast(p.inner_color), @bitCast(p.outer_color), t);
        },
    };
}

fn gradientColors4At(
    draw_list: *DrawList,
    plan: GradientPlan,
    x: i32,
    y: i32,
    comptime use_simd: bool,
) @Vector(16, u8) {
    if (comptime !use_simd) {
        return @bitCast([4]u32{
            gradientColorAt(draw_list, plan, x, y),
            gradientColorAt(draw_list, plan, x + 1, y),
            gradientColorAt(draw_list, plan, x + 2, y),
            gradientColorAt(draw_list, plan, x + 3, y),
        });
    }
    return switch (plan) {
        .linear => |p| {
            const x0 = @as(i64, x);
            const row_q8 = @as(i64, y) * p.step_y_q8;
            const t: @Vector(4, u8) = .{
                gradientCoefficient(p.base_q8 + x0 * p.step_x_q8 + row_q8),
                gradientCoefficient(p.base_q8 + (x0 + 1) * p.step_x_q8 + row_q8),
                gradientCoefficient(p.base_q8 + (x0 + 2) * p.step_x_q8 + row_q8),
                gradientCoefficient(p.base_q8 + (x0 + 3) * p.step_x_q8 + row_q8),
            };
            return gradientColors4(@bitCast(p.start_color), @bitCast(p.end_color), t, true);
        },
        .radial => |p| {
            const lut = ensureRadialGradientLut(draw_list);
            const fy = @as(f32, @floatFromInt(y)) - p.center.y;
            var t: [4]u8 = undefined;
            inline for (0..4) |lane| {
                const fx = @as(f32, @floatFromInt(x + @as(i32, @intCast(lane)))) - p.center.x;
                t[lane] = radialCoefficient(lut, fx * fx + fy * fy, p.inv_radius_squared);
            }
            return gradientColors4(@bitCast(p.inner_color), @bitCast(p.outer_color), t, true);
        },
    };
}

fn gradientCoverage(
    mask: CachedMask,
    inner: ?CachedMask,
    inset: u32,
    sx: u32,
    sy: u32,
    source_x: u32,
    source_y: u32,
    stride: u32,
    aa: bool,
) u8 {
    var coverage: u8 = if (inner != null)
        finalCoverage(mask, inner, inset, sx, sy, true)
    else
        mask.coverage[@as(usize, sy - source_y) * stride + (sx - source_x)];
    if (!aa) coverage = if (coverage >= 128) 255 else 0;
    return coverage;
}

/// Hot path for gradient rounded corners. Absolute target coordinates are
/// sampled, so all four corners and the centre bands share one gradient plan.
fn blitGradientBand(
    target: RenderTarget,
    draw_list: *DrawList,
    bounds: Rect,
    corner: Rect,
    orientation: CornerOrientation,
    mask: CachedMask,
    source_x: u32,
    source_y: u32,
    stride: u32,
    inner: ?CachedMask,
    inset: u32,
    aa: bool,
    plan: GradientPlan,
    comptime use_simd: bool,
) void {
    const is_opaque = gradientIsOpaque(plan);
    const dst_x: u32 = @intCast(bounds.x);
    const dst_y: u32 = @intCast(bounds.y);
    const local_x0: u32 = @intCast(bounds.x - corner.x);
    const local_y0: u32 = @intCast(bounds.y - corner.y);
    var row: u32 = 0;
    while (row < bounds.h) : (row += 1) {
        const sy = sourceY(orientation, mask.radius, local_y0 + row);
        const absolute_y = bounds.y + @as(i32, @intCast(row));
        const dst_base = (@as(usize, dst_y) + row) * target.width + dst_x;
        var x: u32 = 0;
        if (comptime use_simd) {
            while (x + 4 <= bounds.w) : (x += 4) {
                var cov: [4]u8 = undefined;
                inline for (0..4) |lane| {
                    const local_x = local_x0 + x + @as(u32, @intCast(lane));
                    const sx = sourceX(orientation, mask.radius, local_x);
                    cov[lane] = gradientCoverage(mask, inner, inset, sx, sy, source_x, source_y, stride, aa);
                }
                const cov4: @Vector(4, u8) = cov;
                if (@reduce(.Or, cov4) == 0) continue;
                const colors = gradientColors4At(draw_list, plan, bounds.x + @as(i32, @intCast(x)), absolute_y, true);
                const dst: *[4]u32 = target.pixels[dst_base + x ..][0..4];
                if (@reduce(.And, cov4 == @as(@Vector(4, u8), @splat(255))) and is_opaque) {
                    dst.* = @bitCast(colors);
                } else if (@reduce(.And, cov4 == @as(@Vector(4, u8), @splat(255))) and !is_opaque) {
                    dst.* = @bitCast(pixelops.srcOverOpaque4(@bitCast(dst.*), colors));
                } else {
                    dst.* = @bitCast(pixelops.srcOverCoverage4(@bitCast(dst.*), colors, cov4));
                }
            }
        }
        while (x < bounds.w) : (x += 1) {
            const sx = sourceX(orientation, mask.radius, local_x0 + x);
            const coverage = gradientCoverage(mask, inner, inset, sx, sy, source_x, source_y, stride, aa);
            if (coverage == 0) continue;
            const color = gradientColorAt(draw_list, plan, bounds.x + @as(i32, @intCast(x)), absolute_y);
            const dst_index = dst_base + x;
            if (coverage == 255 and is_opaque) {
                target.pixels[dst_index] = color;
            } else if (coverage == 255) {
                target.pixels[dst_index] = pixelops.srcOverOpaque(target.pixels[dst_index], color);
            } else {
                target.pixels[dst_index] = pixelops.srcOverCoverage(target.pixels[dst_index], color, coverage);
            }
        }
    }
}

fn blitGradientCachedCorner(
    target: RenderTarget,
    draw_list: *DrawList,
    dst: Rect,
    clip: Rect,
    orientation: CornerOrientation,
    outer: CachedMask,
    inner: ?CachedMask,
    inset: u32,
    aa: bool,
    plan: GradientPlan,
    comptime use_simd: bool,
) void {
    const bounds = clipRect(dst, clip, target);
    if (bounds.isEmpty()) return;
    draw_list.corner_masks.addCoveragePixels(@as(usize, bounds.w) * bounds.h);
    blitGradientBand(target, draw_list, bounds, dst, orientation, outer, 0, 0, outer.radius, inner, inset, aa, plan, comptime use_simd);
}

fn blitGradientGeneratedBand(
    target: RenderTarget,
    draw_list: *DrawList,
    bounds: Rect,
    corner: Rect,
    orientation: CornerOrientation,
    mask: CachedMask,
    source_x: u32,
    source_y: u32,
    aa: bool,
    plan: GradientPlan,
    comptime use_simd: bool,
) void {
    blitGradientBand(target, draw_list, bounds, corner, orientation, mask, source_x, source_y, bounds.w, null, 0, aa, plan, comptime use_simd);
}

fn drawGradientCornerSet(
    target: RenderTarget,
    draw_list: *DrawList,
    rect: Rect,
    radius: u32,
    aa: bool,
    plan: GradientPlan,
    clip: Rect,
    scale: f32,
    comptime use_simd: bool,
) void {
    if (getCornerMask(draw_list, radius, scale)) |outer_mask| {
        inline for (std.meta.tags(CornerOrientation)) |orientation| {
            blitGradientCachedCorner(target, draw_list, cornerRect(rect, radius, orientation), clip, orientation, outer_mask, null, 0, aa, plan, comptime use_simd);
        }
        return;
    }
    const max_pixels = draw_mod.path_scratch_limit_bytes / draw_mod.path_scratch_bytes_per_pixel;
    for (std.meta.tags(CornerOrientation)) |orientation| {
        const dst = cornerRect(rect, radius, orientation);
        const bounds = clipRect(dst, clip, target);
        if (bounds.isEmpty()) continue;
        const band_h: u32 = @max(1, @as(u32, @intCast(max_pixels / bounds.w)));
        var dy: u32 = 0;
        while (dy < bounds.h) {
            const h = @min(band_h, bounds.h - dy);
            const band_dst = Rect{ .x = bounds.x, .y = bounds.y + @as(i32, @intCast(dy)), .w = bounds.w, .h = h };
            const local_x: u32 = @intCast(band_dst.x - dst.x);
            const local_y: u32 = @intCast(band_dst.y - dst.y);
            const source_x = switch (orientation) {
                .top_left, .bottom_left => local_x,
                .top_right, .bottom_right => radius - local_x - band_dst.w,
            };
            const source_y = switch (orientation) {
                .top_left, .top_right => local_y,
                .bottom_left, .bottom_right => radius - local_y - band_dst.h,
            };
            const pixels = @as(usize, band_dst.w) * band_dst.h;
            draw_list.ensurePathScratch(pixels);
            draw_list.ensureCornerBand(pixels);
            corner_mask.rasterizeBand(radius, source_x, source_y, band_dst.w, band_dst.h, draw_list.path_area, draw_list.path_cover, draw_list.path_coverage);
            @memcpy(draw_list.corner_band[0..pixels], draw_list.path_coverage[0..pixels]);
            const generated = CachedMask{ .coverage = draw_list.corner_band[0..pixels], .radius = radius };
            blitGradientGeneratedBand(target, draw_list, band_dst, dst, orientation, generated, source_x, source_y, aa, plan, comptime use_simd);
            dy += h;
        }
    }
}

fn drawRoundedGradientFilled(
    target: RenderTarget,
    draw_list: *DrawList,
    rect: Rect,
    plan: GradientPlan,
    logical_radius: u32,
    aa: bool,
    clip: Rect,
    scale: f32,
    comptime use_simd: bool,
) void {
    const radius = clampedDeviceRadius(rect, logical_radius, scale);
    if (radius == 0) return drawGradientRect(target, draw_list, rect, plan, clip, comptime use_simd);
    if (rect.w == 0 or rect.h == 0) return;
    const center_w = rect.w - radius * 2;
    drawGradientRect(target, draw_list, .{ .x = rect.x + @as(i32, @intCast(radius)), .y = rect.y, .w = center_w, .h = rect.h }, plan, clip, comptime use_simd);
    const middle_h = rect.h - radius * 2;
    if (middle_h != 0) {
        const middle_y = rect.y + @as(i32, @intCast(radius));
        drawGradientRect(target, draw_list, .{ .x = rect.x, .y = middle_y, .w = radius, .h = middle_h }, plan, clip, comptime use_simd);
        drawGradientRect(target, draw_list, .{ .x = rect.x + @as(i32, @intCast(rect.w - radius)), .y = middle_y, .w = radius, .h = middle_h }, plan, clip, comptime use_simd);
    }
    drawGradientCornerSet(target, draw_list, rect, radius, aa, plan, clip, scale, comptime use_simd);
}

fn drawRoundedOutline(
    target: RenderTarget,
    draw_list: *DrawList,
    rect: Rect,
    col: Color,
    thickness: u32,
    logical_radius: u32,
    aa: bool,
    clip: Rect,
    scale: f32,
    comptime use_simd: bool,
) void {
    const radius = clampedDeviceRadius(rect, logical_radius, scale);
    if (radius == 0) return drawRectOutline(target, rect, col, thickness, clip);
    drawRoundedOutlineDevice(target, draw_list, rect, col, thickness, radius, aa, clip, scale, use_simd);
}

fn drawRoundedOutlineDevice(
    target: RenderTarget,
    draw_list: *DrawList,
    rect: Rect,
    col: Color,
    thickness: u32,
    radius: u32,
    aa: bool,
    clip: Rect,
    scale: f32,
    comptime use_simd: bool,
) void {
    if (rect.w == 0 or rect.h == 0 or radius == 0) return;
    const t = if (thickness == 0) @as(u32, 1) else thickness;
    if (t >= @min(rect.w, rect.h) / 2) {
        return drawRoundedFilledDevice(target, draw_list, rect, col, radius, aa, clip, scale, use_simd);
    }

    const inner_radius = radius -| t;
    const center_x = rect.x + @as(i32, @intCast(radius));
    const center_w = rect.w - radius * 2;
    drawRectFilled(target, .{ .x = center_x, .y = rect.y, .w = center_w, .h = t }, col, clip);
    drawRectFilled(target, .{
        .x = center_x,
        .y = rect.y + @as(i32, @intCast(rect.h - t)),
        .w = center_w,
        .h = t,
    }, col, clip);

    const middle_y = rect.y + @as(i32, @intCast(radius));
    const middle_h = rect.h - radius * 2;
    const side_w = @min(t, radius);
    drawRectFilled(target, .{ .x = rect.x, .y = middle_y, .w = side_w, .h = middle_h }, col, clip);
    drawRectFilled(target, .{
        .x = rect.x + @as(i32, @intCast(rect.w - side_w)),
        .y = middle_y,
        .w = side_w,
        .h = middle_h,
    }, col, clip);

    if (t > radius) {
        const extra = t - radius;
        const inner_y = rect.y + @as(i32, @intCast(t));
        const inner_h = rect.h - t * 2;
        drawRectFilled(target, .{
            .x = rect.x + @as(i32, @intCast(radius)),
            .y = inner_y,
            .w = extra,
            .h = inner_h,
        }, col, clip);
        drawRectFilled(target, .{
            .x = rect.x + @as(i32, @intCast(rect.w - t)),
            .y = inner_y,
            .w = extra,
            .h = inner_h,
        }, col, clip);
    }
    drawCornerSet(target, draw_list, rect, radius, inner_radius, t, aa, col, clip, scale, use_simd);
}

/// Hot path for a single uncached giant corner. It rasterizes only the visible
/// source rectangle in bands, so work stays proportional to corner coverage
/// and retained scratch remains bounded independently of the panel bbox.
fn blitGeneratedCorner(
    target: RenderTarget,
    draw_list: *DrawList,
    dst: Rect,
    clip: Rect,
    orientation: CornerOrientation,
    radius: u32,
    inner_radius: u32,
    inset: u32,
    aa: bool,
    col: Color,
    comptime use_simd: bool,
) void {
    const bounds = clipRect(dst, clip, target);
    if (bounds.isEmpty()) return;
    const max_pixels = draw_mod.path_scratch_limit_bytes / draw_mod.path_scratch_bytes_per_pixel;
    const band_h: u32 = @max(1, @as(u32, @intCast(max_pixels / bounds.w)));
    var dy: u32 = 0;
    while (dy < bounds.h) {
        const h = @min(band_h, bounds.h - dy);
        const band_dst = Rect{ .x = bounds.x, .y = bounds.y + @as(i32, @intCast(dy)), .w = bounds.w, .h = h };
        const local_x: u32 = @intCast(band_dst.x - dst.x);
        const local_y: u32 = @intCast(band_dst.y - dst.y);
        const source_x = switch (orientation) {
            .top_left, .bottom_left => local_x,
            .top_right, .bottom_right => radius - local_x - band_dst.w,
        };
        const source_y = switch (orientation) {
            .top_left, .top_right => local_y,
            .bottom_left, .bottom_right => radius - local_y - band_dst.h,
        };
        const pixels = @as(usize, band_dst.w) * band_dst.h;
        draw_list.ensurePathScratch(pixels);
        draw_list.ensureCornerBand(pixels);
        corner_mask.rasterizeBand(
            radius,
            source_x,
            source_y,
            band_dst.w,
            band_dst.h,
            draw_list.path_area,
            draw_list.path_cover,
            draw_list.path_coverage,
        );
        @memcpy(draw_list.corner_band[0..pixels], draw_list.path_coverage[0..pixels]);

        if (inner_radius != 0) {
            const ix0 = @max(source_x, inset);
            const iy0 = @max(source_y, inset);
            const ix1 = @min(source_x + band_dst.w, inset + inner_radius);
            const iy1 = @min(source_y + band_dst.h, inset + inner_radius);
            if (ix1 > ix0 and iy1 > iy0) {
                const iw = ix1 - ix0;
                const ih = iy1 - iy0;
                corner_mask.rasterizeBand(
                    inner_radius,
                    ix0 - inset,
                    iy0 - inset,
                    iw,
                    ih,
                    draw_list.path_area,
                    draw_list.path_cover,
                    draw_list.path_coverage,
                );
                var iy: u32 = 0;
                while (iy < ih) : (iy += 1) {
                    var ix: u32 = 0;
                    while (ix < iw) : (ix += 1) {
                        const outer_index = @as(usize, iy0 - source_y + iy) * band_dst.w + (ix0 - source_x + ix);
                        const inner_index = @as(usize, iy) * iw + ix;
                        draw_list.corner_band[outer_index] -|= draw_list.path_coverage[inner_index];
                    }
                }
            }
        }

        const generated = CachedMask{ .coverage = draw_list.corner_band[0..pixels], .radius = radius };
        blitGeneratedBand(target, draw_list, band_dst, dst, orientation, generated, source_x, source_y, aa, col, use_simd);
        dy += h;
    }
}

fn blitGeneratedBand(
    target: RenderTarget,
    draw_list: *DrawList,
    bounds: Rect,
    corner: Rect,
    orientation: CornerOrientation,
    mask: CachedMask,
    source_x: u32,
    source_y: u32,
    aa: bool,
    col: Color,
    comptime use_simd: bool,
) void {
    draw_list.corner_masks.addCoveragePixels(@as(usize, bounds.w) * bounds.h);
    const src_u32: u32 = @bitCast(col);
    const src4 = [4]u32{ src_u32, src_u32, src_u32, src_u32 };
    const dst_x: u32 = @intCast(bounds.x);
    const dst_y: u32 = @intCast(bounds.y);
    const local_x0: u32 = @intCast(bounds.x - corner.x);
    const local_y0: u32 = @intCast(bounds.y - corner.y);
    var row: u32 = 0;
    while (row < bounds.h) : (row += 1) {
        const sy = sourceY(orientation, mask.radius, local_y0 + row);
        const dst_base = (dst_y + row) * target.width + dst_x;
        var x: u32 = 0;
        if (col.a == 255) {
            while (x < bounds.w) {
                const sx = sourceX(orientation, mask.radius, local_x0 + x);
                var coverage = mask.coverage[@as(usize, sy - source_y) * bounds.w + (sx - source_x)];
                if (!aa) coverage = if (coverage >= 128) 255 else 0;
                if (coverage == 0) {
                    x += 1;
                    continue;
                }
                if (coverage == 255) {
                    var run = x + 1;
                    while (run < bounds.w) : (run += 1) {
                        const run_sx = sourceX(orientation, mask.radius, local_x0 + run);
                        var run_coverage = mask.coverage[@as(usize, sy - source_y) * bounds.w + (run_sx - source_x)];
                        if (!aa) run_coverage = if (run_coverage >= 128) 255 else 0;
                        if (run_coverage != 255) break;
                    }
                    pixelops.fill32(target.pixels[dst_base + x ..][0 .. run - x], src_u32);
                    x = run;
                    continue;
                }
                if (comptime use_simd) {
                    if (x + 4 <= bounds.w) {
                        var cov: [4]u8 = undefined;
                        inline for (0..4) |lane| {
                            const lane_sx = sourceX(orientation, mask.radius, local_x0 + x + @as(u32, @intCast(lane)));
                            var c = mask.coverage[@as(usize, sy - source_y) * bounds.w + (lane_sx - source_x)];
                            if (!aa) c = if (c >= 128) 255 else 0;
                            cov[lane] = c;
                        }
                        const cov4: @Vector(4, u8) = cov;
                        const dst_chunk: *[4]u32 = target.pixels[dst_base + x ..][0..4];
                        dst_chunk.* = @bitCast(pixelops.srcOverCoverage4(@bitCast(dst_chunk.*), @bitCast(src4), cov4));
                        x += 4;
                        continue;
                    }
                }
                target.pixels[dst_base + x] = pixelops.srcOverCoverage(target.pixels[dst_base + x], src_u32, coverage);
                x += 1;
            }
            continue;
        }
        if (comptime use_simd) {
            while (x + 4 <= bounds.w) : (x += 4) {
                var cov: [4]u8 = undefined;
                inline for (0..4) |lane| {
                    const sx = sourceX(orientation, mask.radius, local_x0 + x + @as(u32, @intCast(lane)));
                    var c = mask.coverage[@as(usize, sy - source_y) * bounds.w + (sx - source_x)];
                    if (!aa) c = if (c >= 128) 255 else 0;
                    cov[lane] = c;
                }
                const cov4: @Vector(4, u8) = cov;
                if (@reduce(.Or, cov4) == 0) continue;
                const dst_chunk: *[4]u32 = target.pixels[dst_base + x ..][0..4];
                dst_chunk.* = @bitCast(pixelops.srcOverCoverage4(@bitCast(dst_chunk.*), @bitCast(src4), cov4));
            }
        }
        while (x < bounds.w) : (x += 1) {
            const sx = sourceX(orientation, mask.radius, local_x0 + x);
            var coverage = mask.coverage[@as(usize, sy - source_y) * bounds.w + (sx - source_x)];
            if (!aa) coverage = if (coverage >= 128) 255 else 0;
            if (coverage == 0) continue;
            target.pixels[dst_base + x] = pixelops.srcOverCoverage(target.pixels[dst_base + x], src_u32, coverage);
        }
    }
}

/// Draw a thickness span off the non-major axis via Bresenham centerline + major-axis test.
/// t==1 matches existing Bresenham. clip/target bounds are computed once at command start and clamp each span.
fn drawLine(target: RenderTarget, p0: Vec2, p1: Vec2, col: Color, thickness: u32, clip: Rect) void {
    const t: u32 = if (thickness == 0) 1 else thickness;
    const offset: i32 = @intCast(t / 2);

    // Drawable bounds = intersection of the centerline AABB expanded by thickness with clip/target
    const min_x = @min(p0.x, p1.x) - offset;
    const max_x = @max(p0.x, p1.x) + offset + @as(i32, @intCast(t)); // exclusive-ish upper for AABB
    const min_y = @min(p0.y, p1.y) - offset;
    const max_y = @max(p0.y, p1.y) + offset + @as(i32, @intCast(t));
    const line_aabb = Rect{
        .x = min_x,
        .y = min_y,
        .w = if (max_x > min_x) @intCast(max_x - min_x) else 0,
        .h = if (max_y > min_y) @intCast(max_y - min_y) else 0,
    };
    const bounds = clipRect(line_aabb, clip, target);
    if (bounds.isEmpty()) return;

    const bx0 = bounds.x;
    const by0 = bounds.y;
    const bx1 = bounds.x + @as(i32, @intCast(bounds.w));
    const by1 = bounds.y + @as(i32, @intCast(bounds.h));

    var x0 = p0.x;
    var y0 = p0.y;
    const x1 = p1.x;
    const y1 = p1.y;

    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = @intCast(@abs(y1 - y0));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx - dy;
    const x_major = dx >= dy;

    while (true) {
        if (x_major) {
            // vertical span: [y - offset, y - offset + t)
            const span_y0 = y0 - offset;
            const span_y1 = span_y0 + @as(i32, @intCast(t));
            if (x0 >= bx0 and x0 < bx1) {
                const y_lo = @max(span_y0, by0);
                const y_hi = @min(span_y1, by1);
                var y = y_lo;
                while (y < y_hi) : (y += 1) {
                    const ux: u32 = @intCast(x0);
                    const uy: u32 = @intCast(y);
                    const idx = uy * target.width + ux;
                    target.pixels[idx] = blendPixel(target.pixels[idx], col);
                }
            }
        } else {
            // horizontal span: [x - offset, x - offset + t)
            const span_x0 = x0 - offset;
            const span_x1 = span_x0 + @as(i32, @intCast(t));
            if (y0 >= by0 and y0 < by1) {
                const x_lo = @max(span_x0, bx0);
                const x_hi = @min(span_x1, bx1);
                var x = x_lo;
                while (x < x_hi) : (x += 1) {
                    const ux: u32 = @intCast(x);
                    const uy: u32 = @intCast(y0);
                    const idx = uy * target.width + ux;
                    target.pixels[idx] = blendPixel(target.pixels[idx], col);
                }
            }
        }
        if (x0 == x1 and y0 == y1) break;
        const e2 = 2 * err;
        if (e2 > -dy) {
            err -= dy;
            x0 += sx;
        }
        if (e2 < dx) {
            err += dx;
            y0 += sy;
        }
    }
}

const PathCmd = @FieldType(draw_mod.DrawCmd, "path");

/// Hot path: flatten once into DrawList-owned buffers, then edge accumulation
/// (per edge), coverage resolve (per bbox row), compositing (every pixel of
/// the clipped bbox, every frame). Capacity grows only when a shape needs more
/// than the last peak; a second `render` of the same cmds does not allocate.
fn drawPath(
    target: RenderTarget,
    draw_list: *DrawList,
    cmd: PathCmd,
    scale: f32,
    comptime use_simd: bool,
) void {
    const target_rect = Rect{ .x = 0, .y = 0, .w = target.width, .h = target.height };
    const clip_t = Rect.intersect(cmd.clip, target_rect);
    if (clip_t.isEmpty() or cmd.verbs.len == 0) return;

    const keep_points = if (cmd.stroke) |st| st.cap != .butt else false;
    flattenPath(draw_list, cmd.verbs, cmd.points, scale, keep_points);

    var pts: []const draw_mod.Vec2f = draw_list.path_flat_pts.items;
    var ends: []const usize = draw_list.path_contour_ends.items;
    if (cmd.stroke) |st| {
        const width = st.width * scale;
        if (!(width > 0) or !std.math.isFinite(width)) return;
        path_stroke.strokePolylines(draw_list, width, st.join, st.cap, st.miter_limit);
        pts = draw_list.path_stroke_pts.items;
        ends = draw_list.path_stroke_ends.items;
    }
    const bbox = bboxFromFlat(pts, clip_t) orelse return;

    // bbox.w is the intersection of the flattened AABB with clip ∩ target, so
    // it cannot exceed target.width. One row is then at most
    // target.width × 9 bytes. A row reaching the 4 MiB cap would need a
    // target about 466_000 px wide, which no presentable framebuffer has.
    const row_bytes = @as(usize, bbox.w) * draw_mod.path_scratch_bytes_per_pixel;
    std.debug.assert(row_bytes <= draw_mod.path_scratch_limit_bytes);
    // Clamp: never above the production ceiling, never below one row. A
    // requested 0 still draws (one row at a time). Holds without the asserts.
    const limit = @max(row_bytes, @min(draw_list.path_scratch_limit, draw_mod.path_scratch_limit_bytes));
    std.debug.assert(limit >= row_bytes);
    std.debug.assert(limit <= draw_mod.path_scratch_limit_bytes);
    const max_px = limit / draw_mod.path_scratch_bytes_per_pixel;
    var band_h: u32 = bbox.h;
    if (@as(usize, bbox.w) * @as(usize, bbox.h) > max_px) {
        band_h = @max(1, @as(u32, @intCast(max_px / @max(@as(usize, bbox.w), 1))));
    }
    std.debug.assert(band_h >= 1);

    var y = bbox.y;
    const y_end = bbox.y + @as(i32, @intCast(bbox.h));
    while (y < y_end) {
        const remain: u32 = @intCast(y_end - y);
        const this_h = @min(band_h, remain);
        const px = @as(usize, bbox.w) * this_h;
        draw_list.ensurePathScratch(px);

        const xform = vector.ScaleTranslate{
            .sx = 1,
            .sy = 1,
            .dx = -@as(f32, @floatFromInt(bbox.x)),
            .dy = -@as(f32, @floatFromInt(y)),
        };
        vector.rasterizePolylinesInto(
            asVectorPts(pts),
            ends,
            xform,
            bbox.w,
            this_h,
            draw_list.path_area,
            draw_list.path_cover,
            draw_list.path_coverage,
        );
        if (!cmd.aa) quantizeCoverage(draw_list.path_coverage[0..px]);
        blitPathCoverage(
            target,
            bbox.x,
            y,
            draw_list.path_coverage[0..px],
            bbox.w,
            this_h,
            cmd.color,
            use_simd,
        );
        y += @as(i32, @intCast(this_h));
    }
}

fn scalePt(p: draw_mod.Vec2f, scale: f32) draw_mod.Vec2f {
    const x = std.math.clamp(@as(f64, p.x) * @as(f64, scale), -@as(f64, std.math.floatMax(f32)), @as(f64, std.math.floatMax(f32)));
    const y = std.math.clamp(@as(f64, p.y) * @as(f64, scale), -@as(f64, std.math.floatMax(f32)), @as(f64, std.math.floatMax(f32)));
    return .{ .x = @floatCast(x), .y = @floatCast(y) };
}

fn asVectorPts(pts: []const draw_mod.Vec2f) []const vector.Vec2f {
    if (pts.len == 0) return &.{};
    return @as([*]const vector.Vec2f, @ptrCast(pts.ptr))[0..pts.len];
}

fn appendFlat(dl: *DrawList, p: draw_mod.Vec2f) void {
    dl.path_flat_pts.append(dl.alloc, p) catch @panic("drawPath: OOM");
}

fn flushContour(dl: *DrawList, start: usize, closed: bool, keep_point: bool) void {
    const end = dl.path_flat_pts.items.len;
    const n = end - start;
    if (n >= 2 or (n == 1 and keep_point)) {
        dl.path_contour_ends.append(dl.alloc, end) catch @panic("drawPath: OOM");
        dl.path_contour_closed.append(dl.alloc, @intFromBool(closed)) catch @panic("drawPath: OOM");
    } else {
        dl.path_flat_pts.shrinkRetainingCapacity(start);
    }
}

/// Flatten once into DrawList-owned buffers. Capacity is retained across
/// commands and frames; growth happens only when this shape needs more.
/// `keep_point` retains a 1-vertex contour (round/square stroke caps).
fn flattenPath(
    dl: *DrawList,
    verbs: []const draw_mod.PathVerb,
    points: []const draw_mod.Vec2f,
    scale: f32,
    keep_point: bool,
) void {
    dl.path_flat_pts.clearRetainingCapacity();
    dl.path_contour_ends.clearRetainingCapacity();
    dl.path_contour_closed.clearRetainingCapacity();
    var pi: usize = 0;
    var cur: draw_mod.Vec2f = .{ .x = 0, .y = 0 };
    var contour_start: usize = 0;
    var have = false;
    for (verbs) |v| {
        switch (v) {
            .move => {
                if (have) flushContour(dl, contour_start, false, keep_point);
                cur = scalePt(points[pi], scale);
                contour_start = dl.path_flat_pts.items.len;
                appendFlat(dl, cur);
                have = true;
                pi += 1;
            },
            .line => {
                cur = scalePt(points[pi], scale);
                appendFlat(dl, cur);
                pi += 1;
            },
            .quad => {
                const c = scalePt(points[pi], scale);
                const e = scalePt(points[pi + 1], scale);
                flattenQuadDraw(dl, cur, c, e, 0);
                cur = e;
                pi += 2;
            },
            .cubic => {
                const c1 = scalePt(points[pi], scale);
                const c2 = scalePt(points[pi + 1], scale);
                const e = scalePt(points[pi + 2], scale);
                flattenCubicDraw(dl, cur, c1, c2, e, 0);
                cur = e;
                pi += 3;
            },
            .close => {
                if (have) {
                    flushContour(dl, contour_start, true, keep_point);
                    have = false;
                }
            },
        }
    }
    if (have) flushContour(dl, contour_start, false, keep_point);
}

fn midPt(a: draw_mod.Vec2f, b: draw_mod.Vec2f) draw_mod.Vec2f {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}

fn flattenQuadDraw(dl: *DrawList, p0: draw_mod.Vec2f, c: draw_mod.Vec2f, p1: draw_mod.Vec2f, depth: u32) void {
    const vp0 = vector.Vec2f{ .x = p0.x, .y = p0.y };
    const vc = vector.Vec2f{ .x = c.x, .y = c.y };
    const vp1 = vector.Vec2f{ .x = p1.x, .y = p1.y };
    const flat = depth >= vector.flatten_max_depth or
        vector.pointToLineDistance(vc, vp0, vp1) <= vector.flatten_tol;
    if (flat) {
        appendFlat(dl, p1);
        return;
    }
    const p01 = midPt(p0, c);
    const p12 = midPt(c, p1);
    const m = midPt(p01, p12);
    flattenQuadDraw(dl, p0, p01, m, depth + 1);
    flattenQuadDraw(dl, m, p12, p1, depth + 1);
}

fn flattenCubicDraw(dl: *DrawList, p0: draw_mod.Vec2f, c1: draw_mod.Vec2f, c2: draw_mod.Vec2f, p1: draw_mod.Vec2f, depth: u32) void {
    const vp0 = vector.Vec2f{ .x = p0.x, .y = p0.y };
    const vc1 = vector.Vec2f{ .x = c1.x, .y = c1.y };
    const vc2 = vector.Vec2f{ .x = c2.x, .y = c2.y };
    const vp1 = vector.Vec2f{ .x = p1.x, .y = p1.y };
    const flat = depth >= vector.flatten_max_depth or
        (vector.pointToLineDistance(vc1, vp0, vp1) <= vector.flatten_tol and
            vector.pointToLineDistance(vc2, vp0, vp1) <= vector.flatten_tol);
    if (flat) {
        appendFlat(dl, p1);
        return;
    }
    const p01 = midPt(p0, c1);
    const p12 = midPt(c1, c2);
    const p23 = midPt(c2, p1);
    const p012 = midPt(p01, p12);
    const p123 = midPt(p12, p23);
    const m = midPt(p012, p123);
    flattenCubicDraw(dl, p0, p01, p012, m, depth + 1);
    flattenCubicDraw(dl, m, p123, p23, p1, depth + 1);
}

/// Intersect the flattened AABB with `clip ∩ target`, then convert. Stroke
/// miter joins can sit outside the input points, but the clamp onto
/// `clip ∩ target` keeps the converted size inside the target. Non-finite
/// values are the only hole: a NaN bypasses clamp and `@intFromFloat` traps.
/// The `render` contract requires input points, stroke width, and
/// `miter_limit` to be finite, which keeps this conversion defined.
fn bboxFromFlat(pts: []const draw_mod.Vec2f, clip_t: Rect) ?Rect {
    if (pts.len == 0) return null;
    var min_x: f32 = pts[0].x;
    var min_y: f32 = pts[0].y;
    var max_x: f32 = pts[0].x;
    var max_y: f32 = pts[0].y;
    for (pts[1..]) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }

    const clip_x0: f64 = @floatFromInt(clip_t.x);
    const clip_y0: f64 = @floatFromInt(clip_t.y);
    const clip_x1: f64 = @as(f64, @floatFromInt(clip_t.x)) + @as(f64, @floatFromInt(clip_t.w));
    const clip_y1: f64 = @as(f64, @floatFromInt(clip_t.y)) + @as(f64, @floatFromInt(clip_t.h));
    const bx0 = std.math.clamp(@as(f64, min_x), clip_x0, clip_x1);
    const by0 = std.math.clamp(@as(f64, min_y), clip_y0, clip_y1);
    const bx1 = std.math.clamp(@as(f64, max_x), clip_x0, clip_x1);
    const by1 = std.math.clamp(@as(f64, max_y), clip_y0, clip_y1);

    const ix0: i32 = @intFromFloat(@floor(bx0));
    const iy0: i32 = @intFromFloat(@floor(by0));
    const ix1: i32 = @intFromFloat(@ceil(bx1));
    const iy1: i32 = @intFromFloat(@ceil(by1));
    if (ix1 <= ix0 or iy1 <= iy0) return null;
    return .{
        .x = ix0,
        .y = iy0,
        .w = @intCast(ix1 - ix0),
        .h = @intCast(iy1 - iy0),
    };
}

fn quantizeCoverage(cov: []u8) void {
    for (cov) |*c| c.* = if (c.* >= 128) 255 else 0;
}

/// Composite 8bpp coverage over an already-clipped dest rect.
/// Clip/bounds are hoisted: the dest rectangle is inside the target.
/// SIMD 4-pixel `srcOverCoverage4` plus a scalar tail; opaque + coverage 255
/// runs go through `fill32`.
fn blitPathCoverage(
    target: RenderTarget,
    dst_x: i32,
    dst_y: i32,
    cov: []const u8,
    w: u32,
    h: u32,
    col: Color,
    comptime use_simd: bool,
) void {
    if (w == 0 or h == 0) return;
    const src_u32: u32 = @bitCast(col);
    const src4 = [4]u32{ src_u32, src_u32, src_u32, src_u32 };
    const ux: u32 = @intCast(dst_x);
    const uy: u32 = @intCast(dst_y);

    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const dst_base = (uy + row) * target.width + ux;
        const cov_base = row * w;
        var x: u32 = 0;
        if (col.a == 255) {
            while (x < w) {
                const c = cov[cov_base + x];
                if (c == 0) {
                    x += 1;
                    continue;
                }
                if (c == 255) {
                    var run = x + 1;
                    while (run < w and cov[cov_base + run] == 255) run += 1;
                    pixelops.fill32(target.pixels[dst_base + x ..][0 .. run - x], src_u32);
                    x = run;
                    continue;
                }
                target.pixels[dst_base + x] = pixelops.srcOverCoverage(target.pixels[dst_base + x], src_u32, c);
                x += 1;
            }
            continue;
        }
        if (comptime use_simd) {
            while (x + 4 <= w) : (x += 4) {
                const cov4: @Vector(4, u8) = @as(*align(1) const @Vector(4, u8), @ptrCast(cov.ptr + cov_base + x)).*;
                if (@reduce(.Or, cov4) == 0) continue;
                const dst_chunk: *[4]u32 = target.pixels[dst_base + x ..][0..4];
                dst_chunk.* = @bitCast(pixelops.srcOverCoverage4(@bitCast(dst_chunk.*), @bitCast(src4), cov4));
            }
        }
        while (x < w) : (x += 1) {
            const c = cov[cov_base + x];
            if (c == 0) continue;
            target.pixels[dst_base + x] = pixelops.srcOverCoverage(target.pixels[dst_base + x], src_u32, c);
        }
    }
}

fn drawImage(
    target: RenderTarget,
    rect: Rect,
    pixels: []const u32,
    src_w: u32,
    src_h: u32,
    clip: Rect,
) void {
    if (src_w == 0 or src_h == 0 or rect.w == 0 or rect.h == 0) return;
    const bounds = clipRect(rect, clip, target);
    if (bounds.isEmpty()) return;

    const bx0: u32 = @intCast(bounds.x);
    const by0: u32 = @intCast(bounds.y);
    const dst_w = rect.w;
    const dst_h = rect.h;

    // 1:1: current SIMD path (source inside bounds is a 1:1 offset)
    if (dst_w == src_w and dst_h == src_h) {
        const src_x_off: u32 = @intCast(bounds.x - rect.x);
        const src_y_off: u32 = @intCast(bounds.y - rect.y);
        var dy: u32 = 0;
        while (dy < bounds.h) : (dy += 1) {
            const src_row = pixels[(src_y_off + dy) * src_w + src_x_off ..];
            const dst_row_base = (by0 + dy) * target.width + bx0;
            var dx: u32 = 0;
            while (dx + 4 <= bounds.w) : (dx += 4) {
                const src_chunk: *const [4]u32 = src_row[dx..][0..4];
                const dst_chunk: *[4]u32 = target.pixels[dst_row_base + dx ..][0..4];
                dst_chunk.* = @bitCast(pixelops.srcOverOpaque4(@bitCast(dst_chunk.*), @bitCast(src_chunk.*)));
            }
            while (dx < bounds.w) : (dx += 1) {
                target.pixels[dst_row_base + dx] = pixelops.srcOverOpaque(target.pixels[dst_row_base + dx], src_row[dx]);
            }
        }
        return;
    }

    // General nearest: sx = floor(dx_local * src_w / dst_w). Integer accumulator avoids per-pixel division.
    // Clip start is local coordinates from the full destination rect.
    const local_x0: u32 = @intCast(bounds.x - rect.x);
    const local_y0: u32 = @intCast(bounds.y - rect.y);

    var dy: u32 = 0;
    while (dy < bounds.h) : (dy += 1) {
        const ly = local_y0 + dy;
        const sy: u32 = @intCast(@divFloor(@as(u64, ly) * @as(u64, src_h), @as(u64, dst_h)));
        const src_row_base = sy * src_w;
        const dst_row_base = (by0 + dy) * target.width + bx0;

        var sx: u32 = @intCast(@divFloor(@as(u64, local_x0) * @as(u64, src_w), @as(u64, dst_w)));
        var rem: u64 = (@as(u64, local_x0) * @as(u64, src_w)) % @as(u64, dst_w);

        var dx: u32 = 0;
        while (dx < bounds.w) {
            // Run length of identical sx (on upscale, multiple dest pixels share one source)
            const remaining = bounds.w - dx;
            var run: u32 = 0;
            var r = rem;
            while (run < remaining) {
                run += 1;
                r += src_w;
                if (r >= dst_w) break; // Same sx through this pixel
            }

            const src_px = pixels[src_row_base + sx];
            var i: u32 = 0;
            while (i + 4 <= run) : (i += 4) {
                const src_chunk = [4]u32{ src_px, src_px, src_px, src_px };
                const dst_chunk: *[4]u32 = target.pixels[dst_row_base + dx + i ..][0..4];
                dst_chunk.* = @bitCast(pixelops.srcOverOpaque4(@bitCast(dst_chunk.*), @bitCast(src_chunk)));
            }
            while (i < run) : (i += 1) {
                target.pixels[dst_row_base + dx + i] = pixelops.srcOverOpaque(target.pixels[dst_row_base + dx + i], src_px);
            }

            dx += run;
            rem += @as(u64, run) * @as(u64, src_w);
            while (rem >= dst_w) {
                rem -= dst_w;
                sx += 1;
            }
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "render: rectFilled fills pixels in clip" {
    var pixels = [_]u32{0xFF000000} ** (10 * 10);
    const target = RenderTarget{ .pixels = &pixels, .width = 10, .height = 10 };

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(10, 10);
    try dl.rectFilled(.{ .x = 2, .y = 2, .w = 4, .h = 4 }, Color.rgba(0xFF, 0, 0, 0xFF));

    const font = font_mod.default_font;
    render(target, &dl, font, 1.0);

    // Center 4x4 is red
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[2 * 10 + 2]);
    // Outside stays as-is
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
}

test "render: pixels outside the clip rect are unchanged" {
    var pixels = [_]u32{0xFF000000} ** (20 * 20);
    const target = RenderTarget{ .pixels = &pixels, .width = 20, .height = 20 };

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(20, 20);
    // Restrict clip to (5,5)-(10,10) then fill the whole area
    try dl.pushClip(.{ .x = 5, .y = 5, .w = 5, .h = 5 });
    try dl.rectFilled(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, Color.rgba(0xFF, 0, 0, 0xFF));
    dl.popClip();

    render(target, &dl, font_mod.default_font, 1.0);

    // Inside clip (5,5) is red
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[5 * 20 + 5]);
    // Outside clip (0,0) stays black
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
    // Outside clip (10,10) stays black
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[10 * 20 + 10]);
}

test "render: image blit" {
    var pixels = [_]u32{0xFF000000} ** (10 * 10);
    const target = RenderTarget{ .pixels = &pixels, .width = 10, .height = 10 };

    // 4x4 white image
    const img_pixels = [_]u32{0xFF_FF_FF_FF} ** 16;

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(10, 10);
    try dl.image(.{ .x = 1, .y = 1, .w = 4, .h = 4 }, &img_pixels, 4, 4);

    render(target, &dl, font_mod.default_font, 1.0);

    // Blitted region is white
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[1 * 10 + 1]);
    // Outside is black
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
}

test "drawRectFilled: opaque fast path is bit-identical to the blend path (including partial clip)" {
    // blendPixel with a=255 returns src (a forced to 0xFF) regardless of dst, so
    // the fast path (@memset) and the blend path must match. Reference is per-pixel blendPixel.
    var prng = std.Random.DefaultPrng.init(0x09A0);
    _ = &prng;
    var px_fast = [_]u32{0} ** (10 * 10);
    var px_ref = [_]u32{0} ** (10 * 10);
    for (&px_fast, &px_ref, 0..) |*a, *b, i| {
        const v: u32 = 0xFF000000 | (@as(u32, @truncate(i)) *% 0x050301);
        a.* = v;
        b.* = v;
    }
    const t_fast = RenderTarget{ .pixels = &px_fast, .width = 10, .height = 10 };
    const t_ref = RenderTarget{ .pixels = &px_ref, .width = 10, .height = 10 };
    const col = Color.rgba(0x12, 0x34, 0x56, 0xFF);
    const rect = Rect{ .x = -2, .y = 3, .w = 8, .h = 20 }; // Including overflow
    const clip = Rect{ .x = 0, .y = 0, .w = 10, .h = 8 };

    drawRectFilled(t_fast, rect, col, clip); // opaque → fast path
    // Reference: per-pixel blend over the clipped range
    const bounds = clipRect(rect, clip, t_ref);
    var y: u32 = @intCast(bounds.y);
    while (y < @as(u32, @intCast(bounds.y)) + bounds.h) : (y += 1) {
        var x: u32 = @intCast(bounds.x);
        while (x < @as(u32, @intCast(bounds.x)) + bounds.w) : (x += 1) {
            px_ref[y * 10 + x] = blendPixel(px_ref[y * 10 + x], col);
        }
    }
    try std.testing.expectEqualSlices(u32, &px_ref, &px_fast);
}

test "drawImage: SIMD path is bit-identical to the per-pixel reference (full alpha range, partial clip, spanning tails)" {
    var prng = std.Random.DefaultPrng.init(0xD12A6E);
    const rng = prng.random();
    // 11x7 image (two 4px chunks + 3px tail per row) at (3,2), with a partial clip intersection
    var img: [11 * 7]u32 = undefined;
    for (&img) |*p| p.* = rng.int(u32);
    var px_simd: [16 * 12]u32 = undefined;
    var px_ref: [16 * 12]u32 = undefined;
    for (&px_simd, &px_ref) |*a, *b| {
        const v = rng.int(u32) | 0xFF000000;
        a.* = v;
        b.* = v;
    }
    const t_simd = RenderTarget{ .pixels = &px_simd, .width = 16, .height = 12 };
    const t_ref = RenderTarget{ .pixels = &px_ref, .width = 16, .height = 12 };
    const rect = Rect{ .x = 3, .y = 2, .w = 11, .h = 7 };
    const clip = Rect{ .x = 0, .y = 0, .w = 12, .h = 8 }; // Clip right and bottom

    // Also compare the negative-coordinate case (overflow left/top) with the same procedure
    const rect_neg = Rect{ .x = -3, .y = -2, .w = 11, .h = 7 };

    drawImage(t_simd, rect, &img, 11, 7, clip);
    drawImage(t_simd, rect_neg, &img, 11, 7, clip);
    // Reference: per-pixel blendPixel
    for ([_]Rect{ rect, rect_neg }) |r| {
        const bounds = clipRect(r, clip, t_ref);
        const sx: u32 = @intCast(bounds.x - r.x);
        const sy: u32 = @intCast(bounds.y - r.y);
        var dy: u32 = 0;
        while (dy < bounds.h) : (dy += 1) {
            var dx: u32 = 0;
            while (dx < bounds.w) : (dx += 1) {
                const si = (sy + dy) * 11 + sx + dx;
                const di = (@as(u32, @intCast(bounds.y)) + dy) * 16 + @as(u32, @intCast(bounds.x)) + dx;
                px_ref[di] = blendPixel(px_ref[di], @bitCast(img[si]));
            }
        }
    }
    try std.testing.expectEqualSlices(u32, &px_ref, &px_simd);
}

// ── scale / thickness / nearest tests ──────────────────────────────

test "scaleRect: floor edges produce seamless tiling" {
    // Adjacent rects [x,x+w) and [x+w,x+w+v) share a common physical boundary with no gap/overlap
    const scales = [_]f32{ 1.0, 1.5, 2.0 };
    for (scales) |s| {
        const a = Rect{ .x = 10, .y = 20, .w = 7, .h = 5 };
        const b = Rect{ .x = 17, .y = 20, .w = 3, .h = 5 }; // right neighbor of a
        const pa = scaleRect(a, s);
        const pb = scaleRect(b, s);
        try std.testing.expectEqual(pa.x + @as(i32, @intCast(pa.w)), pb.x);
        // negative coordinates
        const n = Rect{ .x = -5, .y = -3, .w = 4, .h = 2 };
        const pn = scaleRect(n, s);
        const x0 = floorI32(-5.0 * s);
        const x1 = floorI32((-5 + 4) * s);
        try std.testing.expectEqual(x0, pn.x);
        try std.testing.expectEqual(@as(u32, @intCast(x1 - x0)), pn.w);
    }
}

test "render scale: adjacent rect tiling has no gap or overlap" {
    const scales = [_]f32{ 1.0, 1.5, 2.0 };
    for (scales) |s| {
        // scale a logical 10x10 onto a physical target
        const phys_w: u32 = @intFromFloat(@ceil(20.0 * s));
        const phys_h: u32 = @intFromFloat(@ceil(20.0 * s));
        const n = phys_w * phys_h;
        const buf = try std.testing.allocator.alloc(u32, n);
        defer std.testing.allocator.free(buf);
        @memset(buf, 0xFF000000);
        const target = RenderTarget{ .pixels = buf, .width = phys_w, .height = phys_h };

        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(20, 20);
        const red = Color.rgba(0xFF, 0, 0, 0xFF);
        const green = Color.rgba(0, 0xFF, 0, 0xFF);
        try dl.rectFilled(.{ .x = 2, .y = 3, .w = 5, .h = 4 }, red);
        try dl.rectFilled(.{ .x = 7, .y = 3, .w = 4, .h = 4 }, green);
        render(target, &dl, font_mod.default_font, s);

        const pa = scaleRect(.{ .x = 2, .y = 3, .w = 5, .h = 4 }, s);
        const pb = scaleRect(.{ .x = 7, .y = 3, .w = 4, .h = 4 }, s);
        // boundary column: left of boundary is red, right is green
        try std.testing.expectEqual(pa.x + @as(i32, @intCast(pa.w)), pb.x);
        if (pa.w > 0 and pa.h > 0) {
            const last_x: u32 = @intCast(pa.x + @as(i32, @intCast(pa.w)) - 1);
            const mid_y: u32 = @intCast(pa.y + @as(i32, @intCast(pa.h / 2)));
            try std.testing.expectEqual(@as(u32, 0xFFFF0000), buf[mid_y * phys_w + last_x]);
        }
        if (pb.w > 0 and pb.h > 0) {
            const first_x: u32 = @intCast(pb.x);
            const mid_y: u32 = @intCast(pb.y + @as(i32, @intCast(pb.h / 2)));
            try std.testing.expectEqual(@as(u32, 0xFF00FF00), buf[mid_y * phys_w + first_x]);
        }
    }
}

test "render scale: clip edges use floor rule" {
    const scales = [_]f32{ 1.0, 1.5, 2.0 };
    for (scales) |s| {
        const phys_w: u32 = @intFromFloat(@ceil(20.0 * s));
        const phys_h: u32 = @intFromFloat(@ceil(20.0 * s));
        const n = phys_w * phys_h;
        const buf = try std.testing.allocator.alloc(u32, n);
        defer std.testing.allocator.free(buf);
        @memset(buf, 0xFF000000);
        const target = RenderTarget{ .pixels = buf, .width = phys_w, .height = phys_h };

        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(20, 20);
        try dl.pushClip(.{ .x = 4, .y = 5, .w = 6, .h = 7 });
        try dl.rectFilled(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, Color.rgba(0xFF, 0, 0, 0xFF));
        dl.popClip();
        render(target, &dl, font_mod.default_font, s);

        const pc = scaleRect(.{ .x = 4, .y = 5, .w = 6, .h = 7 }, s);
        // Inside clip is red; outside is black
        if (!pc.isEmpty()) {
            const ix: u32 = @intCast(pc.x);
            const iy: u32 = @intCast(pc.y);
            try std.testing.expectEqual(@as(u32, 0xFFFF0000), buf[iy * phys_w + ix]);
        }
        // Origin is outside clip
        try std.testing.expectEqual(@as(u32, 0xFF000000), buf[0]);
        // Right of clip
        const right: i32 = pc.x + @as(i32, @intCast(pc.w));
        if (right >= 0 and right < @as(i32, @intCast(phys_w)) and pc.y >= 0 and pc.y < @as(i32, @intCast(phys_h))) {
            try std.testing.expectEqual(@as(u32, 0xFF000000), buf[@as(u32, @intCast(pc.y)) * phys_w + @as(u32, @intCast(right))]);
        }
    }
}

test "render scale: nested clip follows floor rule" {
    const s: f32 = 1.5;
    const phys_w: u32 = 40;
    const phys_h: u32 = 40;
    var buf = [_]u32{0xFF000000} ** (40 * 40);
    const target = RenderTarget{ .pixels = &buf, .width = phys_w, .height = phys_h };

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(20, 20);
    try dl.pushClip(.{ .x = 2, .y = 2, .w = 12, .h = 12 });
    try dl.pushClip(.{ .x = 5, .y = 5, .w = 4, .h = 4 });
    try dl.rectFilled(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, Color.rgba(0, 0xFF, 0, 0xFF));
    dl.popClip();
    dl.popClip();
    render(target, &dl, font_mod.default_font, s);

    // effective clip = intersect(outer, inner) then scaled
    const logical_clip = Rect.intersect(
        .{ .x = 2, .y = 2, .w = 12, .h = 12 },
        .{ .x = 5, .y = 5, .w = 4, .h = 4 },
    );
    const pc = scaleRect(logical_clip, s);
    if (!pc.isEmpty()) {
        try std.testing.expectEqual(@as(u32, 0xFF00FF00), buf[@as(u32, @intCast(pc.y)) * phys_w + @as(u32, @intCast(pc.x))]);
    }
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[0]);
}

test "render: line thickness propagates and scales" {
    // thickness=1 horizontal at scale 1 → 1px tall
    {
        var pixels = [_]u32{0xFF000000} ** (20 * 20);
        const target = RenderTarget{ .pixels = &pixels, .width = 20, .height = 20 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(20, 20);
        try dl.line(.{ .x = 2, .y = 10 }, .{ .x = 15, .y = 10 }, Color.rgba(0xFF, 0, 0, 0xFF), 1);
        render(target, &dl, font_mod.default_font, 1.0);
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[10 * 20 + 5]);
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[9 * 20 + 5]);
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[11 * 20 + 5]);
    }
    // thickness=1 at scale 2 → physical thickness 2
    {
        var pixels = [_]u32{0xFF000000} ** (40 * 40);
        const target = RenderTarget{ .pixels = &pixels, .width = 40, .height = 40 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(20, 20);
        try dl.line(.{ .x = 2, .y = 10 }, .{ .x = 15, .y = 10 }, Color.rgba(0xFF, 0, 0, 0xFF), 1);
        render(target, &dl, font_mod.default_font, 2.0);
        // p0=(4,20), t=2, offset=1 → span y [19, 21)
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[19 * 40 + 10]);
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[20 * 40 + 10]);
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[18 * 40 + 10]);
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[21 * 40 + 10]);
    }
    // thickness=0 → physical 1
    {
        var pixels = [_]u32{0xFF000000} ** (20 * 20);
        const target = RenderTarget{ .pixels = &pixels, .width = 20, .height = 20 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(20, 20);
        try dl.line(.{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 }, Color.rgba(0xFF, 0, 0, 0xFF), 0);
        render(target, &dl, font_mod.default_font, 1.0);
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[5 * 20 + 3]);
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[4 * 20 + 3]);
    }
}

test "drawLine: x-major diagonal thickness uses vertical span" {
    // dx > dy: (0,0)→(6,2), thickness=3, offset=1 → each center gets y-1..y+1
    var pixels = [_]u32{0xFF000000} ** (16 * 16);
    const target = RenderTarget{ .pixels = &pixels, .width = 16, .height = 16 };
    const col = Color.rgba(0xFF, 0, 0, 0xFF);
    const clip = Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    drawLine(target, .{ .x = 0, .y = 4 }, .{ .x = 6, .y = 6 }, col, 3, clip);

    // sample a known Bresenham center; vertical span of 3
    // center (0,4): span y [3,6)
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[3 * 16 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[4 * 16 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[5 * 16 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[2 * 16 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[6 * 16 + 0]);

    // no gap on centerline x 0..6 at some y in span
    var x: i32 = 0;
    while (x <= 6) : (x += 1) {
        var any: bool = false;
        var y: i32 = 0;
        while (y < 16) : (y += 1) {
            if (pixels[@as(u32, @intCast(y)) * 16 + @as(u32, @intCast(x))] == 0xFFFF0000) any = true;
        }
        try std.testing.expect(any);
    }
}

test "drawLine: y-major diagonal thickness uses horizontal span" {
    // dy > dx: (2,0)→(4,6), thickness=2, offset=1 → horizontal span of 2
    var pixels = [_]u32{0xFF000000} ** (16 * 16);
    const target = RenderTarget{ .pixels = &pixels, .width = 16, .height = 16 };
    const col = Color.rgba(0, 0xFF, 0, 0xFF);
    const clip = Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    drawLine(target, .{ .x = 4, .y = 0 }, .{ .x = 6, .y = 6 }, col, 2, clip);

    // center (4,0): span x [3, 5)
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), pixels[0 * 16 + 3]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), pixels[0 * 16 + 4]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0 * 16 + 2]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0 * 16 + 5]);

    // no gap on y 0..6
    var y: i32 = 0;
    while (y <= 6) : (y += 1) {
        var any: bool = false;
        var x: i32 = 0;
        while (x < 16) : (x += 1) {
            if (pixels[@as(u32, @intCast(y)) * 16 + @as(u32, @intCast(x))] == 0xFF00FF00) any = true;
        }
        try std.testing.expect(any);
    }
}

test "drawLine: thickness=2/3 patch cable shapes and clip spanning" {
    // fixture: similar to patch cable diagonal thickness 2 and 3
    var pixels = [_]u32{0xFF000000} ** (64 * 64);
    const target = RenderTarget{ .pixels = &pixels, .width = 64, .height = 64 };
    const clip = Rect{ .x = 5, .y = 5, .w = 40, .h = 40 };
    const col = Color.rgba(0xFF, 0x80, 0, 0xFF);

    drawLine(target, .{ .x = 0, .y = 10 }, .{ .x = 50, .y = 30 }, col, 2, clip);
    drawLine(target, .{ .x = 10, .y = 0 }, .{ .x = 40, .y = 50 }, col, 3, clip);

    // something was drawn inside clip
    var painted: usize = 0;
    for (pixels) |p| {
        if (p != 0xFF000000) painted += 1;
    }
    try std.testing.expect(painted > 20);

    // outside clip remains black
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[4 * 64 + 4]);
}

test "drawLine: thickness=1 matches classic Bresenham centers" {
    var pixels = [_]u32{0xFF000000} ** (20 * 20);
    const target = RenderTarget{ .pixels = &pixels, .width = 20, .height = 20 };
    const col = Color.rgba(0xFF, 0, 0, 0xFF);
    const clip = Rect{ .x = 0, .y = 0, .w = 20, .h = 20 };
    drawLine(target, .{ .x = 1, .y = 1 }, .{ .x = 8, .y = 5 }, col, 1, clip);

    // reference classic Bresenham
    var ref = [_]u32{0xFF000000} ** (20 * 20);
    {
        var x0: i32 = 1;
        var y0: i32 = 1;
        const x1: i32 = 8;
        const y1: i32 = 5;
        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = @intCast(@abs(y1 - y0));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx - dy;
        while (true) {
            ref[@as(u32, @intCast(y0)) * 20 + @as(u32, @intCast(x0))] = 0xFFFF0000;
            if (x0 == x1 and y0 == y1) break;
            const e2 = 2 * err;
            if (e2 > -dy) {
                err -= dy;
                x0 += sx;
            }
            if (e2 < dx) {
                err += dx;
                y0 += sy;
            }
        }
    }
    try std.testing.expectEqualSlices(u32, &ref, &pixels);
}

test "render: image nearest scale and clip local mapping" {
    // 2x2 source with unique colors
    const img = [_]u32{
        0xFF0000FF, 0xFF00FF00, // row0: blue, green
        0xFFFF0000, 0xFFFFFFFF, // row1: red, white
    };
    // dest 4x4 at scale=1 (logical dst already 4x4) → 2x2 blocks
    {
        var pixels = [_]u32{0xFF000000} ** (8 * 8);
        const target = RenderTarget{ .pixels = &pixels, .width = 8, .height = 8 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(8, 8);
        try dl.image(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, &img, 2, 2);
        render(target, &dl, font_mod.default_font, 1.0);

        // sx=floor(dx*2/4)=floor(dx/2)
        try std.testing.expectEqual(@as(u32, 0xFF0000FF), pixels[0 * 8 + 0]);
        try std.testing.expectEqual(@as(u32, 0xFF0000FF), pixels[0 * 8 + 1]);
        try std.testing.expectEqual(@as(u32, 0xFF00FF00), pixels[0 * 8 + 2]);
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[2 * 8 + 0]);
        try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[3 * 8 + 3]);
    }
    // scale=2.0 on logical 2x2 dest of 2x2 source → physical 4x4
    {
        var pixels = [_]u32{0xFF000000} ** (8 * 8);
        const target = RenderTarget{ .pixels = &pixels, .width = 8, .height = 8 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(4, 4);
        try dl.image(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, &img, 2, 2);
        render(target, &dl, font_mod.default_font, 2.0);
        // physical dest 4x4, same as above
        try std.testing.expectEqual(@as(u32, 0xFF0000FF), pixels[0 * 8 + 0]);
        try std.testing.expectEqual(@as(u32, 0xFF00FF00), pixels[0 * 8 + 2]);
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[2 * 8 + 0]);
        try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[3 * 8 + 3]);
    }
    // scale=1.5: verify floor(dx * src_w / dst_w)
    {
        // logical 4x4 image of 2x2 src, scale 1.5 → physical dst 6x6
        const s: f32 = 1.5;
        var pixels = [_]u32{0xFF000000} ** (10 * 10);
        const target = RenderTarget{ .pixels = &pixels, .width = 10, .height = 10 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(8, 8);
        try dl.image(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, &img, 2, 2);
        render(target, &dl, font_mod.default_font, s);
        const pr = scaleRect(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, s);
        try std.testing.expectEqual(@as(u32, 6), pr.w);
        try std.testing.expectEqual(@as(u32, 6), pr.h);
        var dy: u32 = 0;
        while (dy < pr.h) : (dy += 1) {
            var dx: u32 = 0;
            while (dx < pr.w) : (dx += 1) {
                const sx = (dx * 2) / pr.w;
                const sy = (dy * 2) / pr.h;
                const expect = img[sy * 2 + sx];
                try std.testing.expectEqual(expect, pixels[dy * 10 + dx]);
            }
        }
    }
    // partial clip: source mapping relative to full dest
    {
        var pixels = [_]u32{0xFF000000} ** (8 * 8);
        const target = RenderTarget{ .pixels = &pixels, .width = 8, .height = 8 };
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(8, 8);
        try dl.pushClip(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
        try dl.image(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, &img, 2, 2);
        dl.popClip();
        render(target, &dl, font_mod.default_font, 1.0);
        // dest local (1,1) → sx=floor(1*2/4)=0, sy=0 → blue
        try std.testing.expectEqual(@as(u32, 0xFF0000FF), pixels[1 * 8 + 1]);
        // dest local (2,2) → sx=1, sy=1 → white
        try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[2 * 8 + 2]);
        // outside clip
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);
        try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[3 * 8 + 3]);
    }
}

test "render: scale=1.0 bit-identical for non-line thickness paths" {
    // rect filled / translucent / outline / 1:1 image — scale 1.0 path
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    var img: [8 * 8]u32 = undefined;
    for (&img) |*p| p.* = rng.int(u32);

    var px = [_]u32{0xFF112233} ** (32 * 32);
    const target = RenderTarget{ .pixels = &px, .width = 32, .height = 32 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(32, 32);
    try dl.rectFilled(.{ .x = 2, .y = 2, .w = 10, .h = 8 }, Color.rgba(0x10, 0x20, 0x30, 0xFF));
    try dl.rectFilled(.{ .x = 4, .y = 4, .w = 6, .h = 4 }, Color.rgba(0xFF, 0, 0, 0x80));
    try dl.rectOutline(.{ .x = 12, .y = 12, .w = 8, .h = 8 }, Color.rgba(0, 0xFF, 0, 0xFF), 2);
    try dl.image(.{ .x = 20, .y = 2, .w = 8, .h = 8 }, &img, 8, 8);
    try dl.line(.{ .x = 0, .y = 30 }, .{ .x = 20, .y = 30 }, Color.rgba(0xFF, 0xFF, 0, 0xFF), 1);

    // render once
    render(target, &dl, font_mod.default_font, 1.0);
    var ref = px;
    // re-render on fresh buffer should match
    @memset(&px, 0xFF112233);
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqualSlices(u32, &ref, &px);
}

test "DrawList.image: accepts non-1:1 destination" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(100, 100);
    const img = [_]u32{0xFFFFFFFF} ** 4;
    try dl.image(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, &img, 2, 2);
    try std.testing.expectEqual(@as(usize, 1), dl.cmds.items.len);
    try std.testing.expectEqual(@as(u32, 10), dl.cmds.items[0].image.rect.w);
    try std.testing.expectEqual(@as(u32, 2), dl.cmds.items[0].image.src_w);
}

test "scaleThickness: round and min 1" {
    try std.testing.expectEqual(@as(u32, 1), scaleThickness(0, 1.0));
    try std.testing.expectEqual(@as(u32, 1), scaleThickness(1, 1.0));
    try std.testing.expectEqual(@as(u32, 2), scaleThickness(1, 2.0));
    try std.testing.expectEqual(@as(u32, 2), scaleThickness(1, 1.5)); // round(1.5)=2
    try std.testing.expectEqual(@as(u32, 3), scaleThickness(2, 1.5)); // round(3.0)=3
    try std.testing.expectEqual(@as(u32, 1), scaleThickness(1, 0.4)); // round(0.4)=0 → max(1)
}

// ── text scale dispatch ────────────────────────────────────────────

test "render text scale==1.0 passes original pos/clip and scale=1.0" {
    const Spy = struct {
        var last_pos: Vec2 = .{ .x = -1, .y = -1 };
        var last_clip: Rect = .{ .x = -1, .y = -1, .w = 0, .h = 0 };
        var last_scale: f32 = -1;
        var calls: u32 = 0;
        fn m(_: *const anyopaque, _: []const u8) u32 {
            return 0;
        }
        fn d(_: *const anyopaque, _: RenderTarget, pos: Vec2, _: []const u8, _: Color, clip: Rect, scale: f32) void {
            last_pos = pos;
            last_clip = clip;
            last_scale = scale;
            calls += 1;
        }
        fn me(_: *const anyopaque) font_mod.Metrics {
            return .{ .line_height = 16, .ascent = 12, .descent = 4 };
        }
        const dummy: u8 = 0;
        const vt: Font.VTable = .{ .measure = m, .drawTo = d, .metrics = me };
        const font: Font = .{ .ptr = &dummy, .vtable = &vt };
    };
    Spy.calls = 0;

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(100, 100);
    const logical_clip = Rect{ .x = 5, .y = 6, .w = 40, .h = 30 };
    try dl.pushClip(logical_clip);
    try dl.text(.{ .x = 10, .y = 20 }, "hi", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));

    var px = [_]u32{0} ** (100 * 100);
    const target = RenderTarget{ .pixels = &px, .width = 100, .height = 100 };
    render(target, &dl, Spy.font, 1.0);

    try std.testing.expectEqual(@as(u32, 1), Spy.calls);
    try std.testing.expectEqual(@as(i32, 10), Spy.last_pos.x);
    try std.testing.expectEqual(@as(i32, 20), Spy.last_pos.y);
    try std.testing.expectEqual(logical_clip.x, Spy.last_clip.x);
    try std.testing.expectEqual(logical_clip.y, Spy.last_clip.y);
    try std.testing.expectEqual(logical_clip.w, Spy.last_clip.w);
    try std.testing.expectEqual(logical_clip.h, Spy.last_clip.h);
    try std.testing.expectEqual(@as(f32, 1.0), Spy.last_scale);
}

test "render text scale==2.0 passes scalePoint/scaleRect results and scale=2.0" {
    const Spy = struct {
        var last_pos: Vec2 = .{ .x = -1, .y = -1 };
        var last_clip: Rect = .{ .x = -1, .y = -1, .w = 0, .h = 0 };
        var last_scale: f32 = -1;
        var calls: u32 = 0;
        fn m(_: *const anyopaque, _: []const u8) u32 {
            return 0;
        }
        fn d(_: *const anyopaque, _: RenderTarget, pos: Vec2, _: []const u8, _: Color, clip: Rect, scale: f32) void {
            last_pos = pos;
            last_clip = clip;
            last_scale = scale;
            calls += 1;
        }
        fn me(_: *const anyopaque) font_mod.Metrics {
            return .{ .line_height = 16, .ascent = 12, .descent = 4 };
        }
        const dummy: u8 = 0;
        const vt: Font.VTable = .{ .measure = m, .drawTo = d, .metrics = me };
        const font: Font = .{ .ptr = &dummy, .vtable = &vt };
    };
    Spy.calls = 0;

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(100, 100);
    const logical_pos = Vec2{ .x = 10, .y = 20 };
    const logical_clip = Rect{ .x = 5, .y = 6, .w = 40, .h = 30 };
    try dl.pushClip(logical_clip);
    try dl.text(logical_pos, "hi", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));

    var px = [_]u32{0} ** (200 * 200);
    const target = RenderTarget{ .pixels = &px, .width = 200, .height = 200 };
    const s: f32 = 2.0;
    render(target, &dl, Spy.font, s);

    const expect_pos = scalePoint(logical_pos, s);
    const expect_clip = scaleRect(logical_clip, s);
    try std.testing.expectEqual(@as(u32, 1), Spy.calls);
    try std.testing.expectEqual(expect_pos.x, Spy.last_pos.x);
    try std.testing.expectEqual(expect_pos.y, Spy.last_pos.y);
    try std.testing.expectEqual(expect_clip.x, Spy.last_clip.x);
    try std.testing.expectEqual(expect_clip.y, Spy.last_clip.y);
    try std.testing.expectEqual(expect_clip.w, Spy.last_clip.w);
    try std.testing.expectEqual(expect_clip.h, Spy.last_clip.h);
    try std.testing.expectEqual(@as(f32, 2.0), Spy.last_scale);
}

test "render text with empty clip does not call drawTo" {
    const Spy = struct {
        var calls: u32 = 0;
        fn m(_: *const anyopaque, _: []const u8) u32 {
            return 0;
        }
        fn d(_: *const anyopaque, _: RenderTarget, _: Vec2, _: []const u8, _: Color, _: Rect, _: f32) void {
            calls += 1;
        }
        fn me(_: *const anyopaque) font_mod.Metrics {
            return .{ .line_height = 16, .ascent = 12, .descent = 4 };
        }
        const dummy: u8 = 0;
        const vt: Font.VTable = .{ .measure = m, .drawTo = d, .metrics = me };
        const font: Font = .{ .ptr = &dummy, .vtable = &vt };
    };
    Spy.calls = 0;

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(100, 100);
    try dl.pushClip(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
    try dl.text(.{ .x = 0, .y = 0 }, "hi", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));

    var px = [_]u32{0} ** (100 * 100);
    const target = RenderTarget{ .pixels = &px, .width = 100, .height = 100 };
    render(target, &dl, Spy.font, 1.0);
    try std.testing.expectEqual(@as(u32, 0), Spy.calls);
    render(target, &dl, Spy.font, 2.0);
    try std.testing.expectEqual(@as(u32, 0), Spy.calls);
}

test "text clip scale rules match rect" {
    const scales = [_]f32{ 1.5, 2.0 };
    for (scales) |s| {
        const logical = Rect{ .x = 4, .y = 5, .w = 6, .h = 7 };
        // same scaleRect as the rect path
        const via_rect = scaleRect(logical, s);

        const Spy = struct {
            var last_clip: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            fn m(_: *const anyopaque, _: []const u8) u32 {
                return 0;
            }
            fn d(_: *const anyopaque, _: RenderTarget, _: Vec2, _: []const u8, _: Color, clip: Rect, _: f32) void {
                last_clip = clip;
            }
            fn me(_: *const anyopaque) font_mod.Metrics {
                return .{ .line_height = 16, .ascent = 12, .descent = 4 };
            }
            const dummy: u8 = 0;
            const vt: Font.VTable = .{ .measure = m, .drawTo = d, .metrics = me };
            const font: Font = .{ .ptr = &dummy, .vtable = &vt };
        };

        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(100, 100);
        try dl.pushClip(logical);
        try dl.text(.{ .x = 0, .y = 0 }, "x", Color.rgba(0xFF, 0xFF, 0xFF, 0xFF));
        var px = [_]u32{0} ** (200 * 200);
        const target = RenderTarget{ .pixels = &px, .width = 200, .height = 200 };
        render(target, &dl, Spy.font, s);
        try std.testing.expectEqual(via_rect.x, Spy.last_clip.x);
        try std.testing.expectEqual(via_rect.y, Spy.last_clip.y);
        try std.testing.expectEqual(via_rect.w, Spy.last_clip.w);
        try std.testing.expectEqual(via_rect.h, Spy.last_clip.h);
    }
}

fn pathPx(pixels: []const u32, stride: u32, x: u32, y: u32) u32 {
    return pixels[y * stride + x];
}

test "path fill: pixel-aligned convex rect is opaque inside and empty outside" {
    var pixels = [_]u32{0xFF000000} ** (8 * 8);
    const target = RenderTarget{ .pixels = &pixels, .width = 8, .height = 8 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(8, 8);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 2, .y = 2 });
    try b.lineTo(.{ .x = 6, .y = 2 });
    try b.lineTo(.{ .x = 6, .y = 6 });
    try b.lineTo(.{ .x = 2, .y = 6 });
    try b.close();
    try b.finish(.{ .color = Color.rgba(0xFF, 0, 0, 0xFF) });
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pathPx(&pixels, 8, 3, 3));
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pathPx(&pixels, 8, 5, 5));
    try std.testing.expectEqual(@as(u32, 0xFF000000), pathPx(&pixels, 8, 0, 0));
    try std.testing.expectEqual(@as(u32, 0xFF000000), pathPx(&pixels, 8, 7, 7));
}

test "path fill: concave chevron has a hollow notch" {
    var pixels = [_]u32{0xFF000000} ** (16 * 16);
    const target = RenderTarget{ .pixels = &pixels, .width = 16, .height = 16 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(16, 16);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 1, .y = 1 });
    try b.lineTo(.{ .x = 15, .y = 1 });
    try b.lineTo(.{ .x = 15, .y = 15 });
    try b.lineTo(.{ .x = 8, .y = 8 });
    try b.lineTo(.{ .x = 1, .y = 15 });
    try b.close();
    try b.finish(.{ .color = Color.rgba(0, 0xFF, 0, 0xFF) });
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), pathPx(&pixels, 16, 2, 2));
    try std.testing.expectEqual(@as(u32, 0xFF000000), pathPx(&pixels, 16, 8, 12));
}

test "path fill: opposite-winding inner contour is a hole" {
    var pixels = [_]u32{0xFF000000} ** (12 * 12);
    const target = RenderTarget{ .pixels = &pixels, .width = 12, .height = 12 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(12, 12);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 1, .y = 1 });
    try b.lineTo(.{ .x = 11, .y = 1 });
    try b.lineTo(.{ .x = 11, .y = 11 });
    try b.lineTo(.{ .x = 1, .y = 11 });
    try b.close();
    try b.moveTo(.{ .x = 4, .y = 4 });
    try b.lineTo(.{ .x = 4, .y = 8 });
    try b.lineTo(.{ .x = 8, .y = 8 });
    try b.lineTo(.{ .x = 8, .y = 4 });
    try b.close();
    try b.finish(.{ .color = Color.rgba(0, 0, 0xFF, 0xFF) });
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), pathPx(&pixels, 12, 2, 2));
    try std.testing.expectEqual(@as(u32, 0xFF000000), pathPx(&pixels, 12, 5, 5));
    try std.testing.expectEqual(@as(u32, 0xFF000000), pathPx(&pixels, 12, 6, 6));
}

test "path fill: same-winding inner contour fills the interior" {
    var pixels = [_]u32{0xFF000000} ** (12 * 12);
    const target = RenderTarget{ .pixels = &pixels, .width = 12, .height = 12 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(12, 12);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 1, .y = 1 });
    try b.lineTo(.{ .x = 11, .y = 1 });
    try b.lineTo(.{ .x = 11, .y = 11 });
    try b.lineTo(.{ .x = 1, .y = 11 });
    try b.close();
    try b.moveTo(.{ .x = 4, .y = 4 });
    try b.lineTo(.{ .x = 8, .y = 4 });
    try b.lineTo(.{ .x = 8, .y = 8 });
    try b.lineTo(.{ .x = 4, .y = 8 });
    try b.close();
    try b.finish(.{ .color = Color.rgba(0xFF, 0xFF, 0, 0xFF) });
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqual(@as(u32, 0xFFFFFF00), pathPx(&pixels, 12, 2, 2));
    try std.testing.expectEqual(@as(u32, 0xFFFFFF00), pathPx(&pixels, 12, 5, 5));
}

test "path fill: several moves are several contours" {
    var pixels = [_]u32{0xFF000000} ** (16 * 8);
    const target = RenderTarget{ .pixels = &pixels, .width = 16, .height = 8 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(16, 8);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 1, .y = 1 });
    try b.lineTo(.{ .x = 4, .y = 1 });
    try b.lineTo(.{ .x = 4, .y = 4 });
    try b.lineTo(.{ .x = 1, .y = 4 });
    try b.moveTo(.{ .x = 8, .y = 1 });
    try b.lineTo(.{ .x = 12, .y = 1 });
    try b.lineTo(.{ .x = 12, .y = 4 });
    try b.lineTo(.{ .x = 8, .y = 4 });
    try b.finish(.{ .color = Color.rgba(0xFF, 0, 0xFF, 0xFF) });
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqual(@as(u32, 0xFFFF00FF), pathPx(&pixels, 16, 2, 2));
    try std.testing.expectEqual(@as(u32, 0xFFFF00FF), pathPx(&pixels, 16, 10, 2));
    try std.testing.expectEqual(@as(u32, 0xFF000000), pathPx(&pixels, 16, 6, 2));
}

test "path fill: implicit close matches an explicit close" {
    var a = [_]u32{0xFF000000} ** (8 * 8);
    var bpx = [_]u32{0xFF000000} ** (8 * 8);
    const ta = RenderTarget{ .pixels = &a, .width = 8, .height = 8 };
    const tb = RenderTarget{ .pixels = &bpx, .width = 8, .height = 8 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var dl_open = DrawList.init(std.testing.allocator);
    defer dl_open.deinit();
    dl_open.reset(8, 8);
    var p0 = dl_open.beginPath(arena.allocator());
    try p0.moveTo(.{ .x = 1, .y = 1 });
    try p0.lineTo(.{ .x = 6, .y = 1 });
    try p0.lineTo(.{ .x = 6, .y = 6 });
    try p0.lineTo(.{ .x = 1, .y = 6 });
    try p0.finish(.{ .color = Color.rgba(0xFF, 0, 0, 0xFF) });

    var dl_closed = DrawList.init(std.testing.allocator);
    defer dl_closed.deinit();
    dl_closed.reset(8, 8);
    var p1 = dl_closed.beginPath(arena.allocator());
    try p1.moveTo(.{ .x = 1, .y = 1 });
    try p1.lineTo(.{ .x = 6, .y = 1 });
    try p1.lineTo(.{ .x = 6, .y = 6 });
    try p1.lineTo(.{ .x = 1, .y = 6 });
    try p1.close();
    try p1.finish(.{ .color = Color.rgba(0xFF, 0, 0, 0xFF) });

    render(ta, &dl_open, font_mod.default_font, 1.0);
    render(tb, &dl_closed, font_mod.default_font, 1.0);
    try std.testing.expectEqualSlices(u32, &a, &bpx);
}

test "path fill: AA off quantizes coverage at 128" {
    var on = [_]u32{0xFF000000} ** (8 * 8);
    var off = [_]u32{0xFF000000} ** (8 * 8);
    const t_on = RenderTarget{ .pixels = &on, .width = 8, .height = 8 };
    const t_off = RenderTarget{ .pixels = &off, .width = 8, .height = 8 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var dl_on = DrawList.init(std.testing.allocator);
    defer dl_on.deinit();
    dl_on.reset(8, 8);
    var b_on = dl_on.beginPath(arena.allocator());
    try b_on.moveTo(.{ .x = 1.5, .y = 1 });
    try b_on.lineTo(.{ .x = 6.5, .y = 1 });
    try b_on.lineTo(.{ .x = 6.5, .y = 6 });
    try b_on.lineTo(.{ .x = 1.5, .y = 6 });
    try b_on.close();
    try b_on.finish(.{ .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .aa = true });

    var dl_off = DrawList.init(std.testing.allocator);
    defer dl_off.deinit();
    dl_off.reset(8, 8);
    var b_off = dl_off.beginPath(arena.allocator());
    try b_off.moveTo(.{ .x = 1.5, .y = 1 });
    try b_off.lineTo(.{ .x = 6.5, .y = 1 });
    try b_off.lineTo(.{ .x = 6.5, .y = 6 });
    try b_off.lineTo(.{ .x = 1.5, .y = 6 });
    try b_off.close();
    try b_off.finish(.{ .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .aa = false });

    render(t_on, &dl_on, font_mod.default_font, 1.0);
    render(t_off, &dl_off, font_mod.default_font, 1.0);

    // AA-on edge is a midtone; AA-off is either white or black.
    const edge_on = pathPx(&on, 8, 1, 3);
    const edge_off = pathPx(&off, 8, 1, 3);
    try std.testing.expect(edge_on != 0xFF000000 and edge_on != 0xFFFFFFFF);
    try std.testing.expect(edge_off == 0xFF000000 or edge_off == 0xFFFFFFFF);
}

test "path fill: coverage scratch peak stays at or under the 4 MiB cap" {
    var pixels = [_]u32{0xFF000000} ** (64 * 64);
    const target = RenderTarget{ .pixels = &pixels, .width = 64, .height = 64 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.lineTo(.{ .x = 64, .y = 0 });
    try b.lineTo(.{ .x = 64, .y = 64 });
    try b.lineTo(.{ .x = 0, .y = 64 });
    try b.close();
    try b.finish(.{ .color = Color.rgba(0xFF, 0, 0, 0xFF) });
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expect(dl.path_scratch_peak_bytes <= draw_mod.path_scratch_limit_bytes);
}

test "path fill: a bbox over the scratch cap is banded and the peak stays at the cap" {
    const W: u32 = 512;
    const H: u32 = 1024;
    const buf = try std.testing.allocator.alloc(u32, W * H);
    defer std.testing.allocator.free(buf);
    @memset(buf, 0xFF000000);
    const target = RenderTarget{ .pixels = buf, .width = W, .height = H };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(W, H);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 0, .y = 0 });
    try b.lineTo(.{ .x = @floatFromInt(W), .y = 0 });
    try b.lineTo(.{ .x = @floatFromInt(W), .y = @floatFromInt(H) });
    try b.lineTo(.{ .x = 0, .y = @floatFromInt(H) });
    try b.close();
    try b.finish(.{ .color = Color.rgba(0x20, 0x20, 0x20, 0xFF) });
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expect(dl.path_scratch_peak_bytes <= draw_mod.path_scratch_limit_bytes);
    try std.testing.expect(dl.path_scratch_pixels <= draw_mod.path_scratch_limit_bytes / draw_mod.path_scratch_bytes_per_pixel);
    try std.testing.expectEqual(@as(u32, 0xFF202020), buf[10 * W + 10]);
    try std.testing.expectEqual(@as(u32, 0xFF202020), buf[(H - 10) * W + (W - 10)]);
}

test "path flatten: max distance to a quadratic stays within 0.2 device px at scale 1/2/4" {
    const p0 = vector.Vec2f{ .x = 0, .y = 0 };
    const c = vector.Vec2f{ .x = 10, .y = 20 };
    const p1 = vector.Vec2f{ .x = 20, .y = 0 };
    for ([_]f32{ 1, 2, 4 }) |s| {
        const q0 = vector.Vec2f{ .x = p0.x * s, .y = p0.y * s };
        const qc = vector.Vec2f{ .x = c.x * s, .y = c.y * s };
        const q1 = vector.Vec2f{ .x = p1.x * s, .y = p1.y * s };
        var pts: std.ArrayList(vector.Vec2f) = .empty;
        defer pts.deinit(std.testing.allocator);
        try pts.append(std.testing.allocator, q0);
        try vector.flattenQuadInto(&pts, std.testing.allocator, q0, qc, q1, 0);
        var t: f32 = 0;
        var max_d: f32 = 0;
        while (t <= 1.0) : (t += 0.002) {
            const sample = vector.evalQuad(q0, qc, q1, t);
            var best: f32 = std.math.floatMax(f32);
            var i: usize = 0;
            while (i + 1 < pts.items.len) : (i += 1) {
                const d = vector.pointToLineDistance(sample, pts.items[i], pts.items[i + 1]);
                best = @min(best, d);
            }
            max_d = @max(max_d, best);
        }
        try std.testing.expect(max_d <= vector.flatten_tol + 1e-4);
    }
}

test "path flatten: max distance to a cubic stays within 0.2 device px at scale 1/2/4" {
    const p0 = vector.Vec2f{ .x = 0, .y = 0 };
    const c1 = vector.Vec2f{ .x = 0, .y = 16 };
    const c2 = vector.Vec2f{ .x = 16, .y = 16 };
    const p1 = vector.Vec2f{ .x = 16, .y = 0 };
    for ([_]f32{ 1, 2, 4 }) |s| {
        const q0 = vector.Vec2f{ .x = p0.x * s, .y = p0.y * s };
        const qc1 = vector.Vec2f{ .x = c1.x * s, .y = c1.y * s };
        const qc2 = vector.Vec2f{ .x = c2.x * s, .y = c2.y * s };
        const q1 = vector.Vec2f{ .x = p1.x * s, .y = p1.y * s };
        var pts: std.ArrayList(vector.Vec2f) = .empty;
        defer pts.deinit(std.testing.allocator);
        try pts.append(std.testing.allocator, q0);
        try vector.flattenCubicInto(&pts, std.testing.allocator, q0, qc1, qc2, q1, 0);
        var t: f32 = 0;
        var max_d: f32 = 0;
        while (t <= 1.0) : (t += 0.002) {
            const sample = vector.evalCubic(q0, qc1, qc2, q1, t);
            var best: f32 = std.math.floatMax(f32);
            var i: usize = 0;
            while (i + 1 < pts.items.len) : (i += 1) {
                const d = vector.pointToLineDistance(sample, pts.items[i], pts.items[i + 1]);
                best = @min(best, d);
            }
            max_d = @max(max_d, best);
        }
        try std.testing.expect(max_d <= vector.flatten_tol + 1e-4);
    }
}

test "path flatten: depth-cap error is recorded for a spike quadratic" {
    // Starting at flatten_max_depth forces the remaining chord (the accepted
    // approximation when the cap is hit). Control is 1000 px off the chord.
    const p0 = vector.Vec2f{ .x = 0, .y = 0 };
    const c = vector.Vec2f{ .x = 1000, .y = 1000 };
    const p1 = vector.Vec2f{ .x = 0.001, .y = 0 };
    var pts: std.ArrayList(vector.Vec2f) = .empty;
    defer pts.deinit(std.testing.allocator);
    try pts.append(std.testing.allocator, p0);
    try vector.flattenQuadInto(&pts, std.testing.allocator, p0, c, p1, vector.flatten_max_depth);
    var t: f32 = 0;
    var max_d: f32 = 0;
    while (t <= 1.0) : (t += 0.002) {
        const sample = vector.evalQuad(p0, c, p1, t);
        var best: f32 = std.math.floatMax(f32);
        var i: usize = 0;
        while (i + 1 < pts.items.len) : (i += 1) {
            const d = vector.pointToLineDistance(sample, pts.items[i], pts.items[i + 1]);
            best = @min(best, d);
        }
        max_d = @max(max_d, best);
    }
    // The cap is the contract: the remaining error is accepted. Mid-curve
    // to the leftover chord is about 500 device px for this spike.
    try std.testing.expect(max_d > 400);
    try std.testing.expect(max_d < 600);
}

fn fillComplexPath(dl: *DrawList, arena: std.mem.Allocator, aa: bool) !void {
    var b = dl.beginPath(arena);
    try b.moveTo(.{ .x = 2, .y = 2 });
    try b.lineTo(.{ .x = 30, .y = 4 });
    try b.quadTo(.{ .x = 34, .y = 16 }, .{ .x = 28, .y = 30 });
    try b.lineTo(.{ .x = 4, .y = 28 });
    try b.close();
    try b.moveTo(.{ .x = 12, .y = 12 });
    try b.lineTo(.{ .x = 12, .y = 20 });
    try b.lineTo(.{ .x = 20, .y = 20 });
    try b.lineTo(.{ .x = 20, .y = 12 });
    try b.close();
    try b.finish(.{ .color = Color.rgba(0x40, 0x80, 0xC0, 0xA0), .aa = aa });
}

test "path render: second frame allocates nothing (FailingAllocator)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    try fillComplexPath(&dl, arena.allocator(), true);

    var pixels = [_]u32{0xFF101010} ** (64 * 64);
    const target = RenderTarget{ .pixels = &pixels, .width = 64, .height = 64 };
    render(target, &dl, font_mod.default_font, 1.0);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    dl.alloc = failing.allocator();
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    dl.alloc = std.testing.allocator;
}

test "path blit: SIMD matches scalar on a translucent path at least 4 px wide" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(32, 16);
    try fillComplexPath(&dl, arena.allocator(), true);
    const cmd = dl.cmds.items[0].path;

    var pix_simd = [_]u32{0xFF334455} ** (32 * 16);
    var pix_sca = pix_simd;
    drawPath(.{ .pixels = &pix_simd, .width = 32, .height = 16 }, &dl, cmd, 1.0, true);
    drawPath(.{ .pixels = &pix_sca, .width = 32, .height = 16 }, &dl, cmd, 1.0, false);
    try std.testing.expectEqualSlices(u32, &pix_sca, &pix_simd);
}

test "path fill: a requested scratch limit of 0 still matches the default and stays under the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var dl_def = DrawList.init(std.testing.allocator);
    defer dl_def.deinit();
    dl_def.reset(32, 32);
    try fillComplexPath(&dl_def, arena.allocator(), true);

    var dl_zero = DrawList.init(std.testing.allocator);
    defer dl_zero.deinit();
    dl_zero.reset(32, 32);
    try fillComplexPath(&dl_zero, arena.allocator(), true);
    dl_zero.path_scratch_limit = 0;

    var pix_def = [_]u32{0xFF000000} ** (32 * 32);
    var pix_zero = pix_def;
    render(.{ .pixels = &pix_def, .width = 32, .height = 32 }, &dl_def, font_mod.default_font, 1.0);
    render(.{ .pixels = &pix_zero, .width = 32, .height = 32 }, &dl_zero, font_mod.default_font, 1.0);
    try std.testing.expectEqualSlices(u32, &pix_def, &pix_zero);
    try std.testing.expect(dl_zero.path_scratch_peak_bytes <= draw_mod.path_scratch_limit_bytes);
}

test "path fill: banding matches an unbanded rasterize for a diagonal, a curve, and a hole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var dl_full = DrawList.init(std.testing.allocator);
    defer dl_full.deinit();
    dl_full.reset(32, 32);
    try fillComplexPath(&dl_full, arena.allocator(), true);

    var dl_band = DrawList.init(std.testing.allocator);
    defer dl_band.deinit();
    dl_band.reset(32, 32);
    try fillComplexPath(&dl_band, arena.allocator(), true);
    // 4 rows × 32 px × 9 bytes = 1152; a 32×32 shape must split.
    dl_band.path_scratch_limit = 32 * 4 * draw_mod.path_scratch_bytes_per_pixel;

    var pix_full = [_]u32{0xFF000000} ** (32 * 32);
    var pix_band = pix_full;
    render(.{ .pixels = &pix_full, .width = 32, .height = 32 }, &dl_full, font_mod.default_font, 1.0);
    render(.{ .pixels = &pix_band, .width = 32, .height = 32 }, &dl_band, font_mod.default_font, 1.0);
    try std.testing.expectEqualSlices(u32, &pix_full, &pix_band);
    try std.testing.expect(dl_band.path_scratch_peak_bytes <= dl_band.path_scratch_limit);
}

test "path stroke: a 1px AA hairline is visible and is not a hollow double line" {
    var pixels = [_]u32{0xFF000000} ** (32 * 16);
    const target = RenderTarget{ .pixels = &pixels, .width = 32, .height = 16 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(32, 16);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 4, .y = 8.5 });
    try b.lineTo(.{ .x = 28, .y = 8.5 });
    try b.stroke(.{ .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .width = 1, .aa = true });
    render(target, &dl, font_mod.default_font, 1.0);

    const mid = pathPx(&pixels, 32, 16, 8);
    try std.testing.expect(mid != 0xFF000000);
    // Centered on the pixel, a 1px stroke is a solid band, not two edge
    // traces with a dark core.
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), mid);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pathPx(&pixels, 32, 16, 6));
    try std.testing.expectEqual(@as(u32, 0xFF000000), pathPx(&pixels, 32, 16, 10));
}

test "path stroke: join miter vs bevel and cap square vs butt paint different pixels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var pix_miter = [_]u32{0xFF000000} ** (24 * 24);
    var pix_bevel = pix_miter;
    {
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(24, 24);
        var b = dl.beginPath(arena.allocator());
        try b.moveTo(.{ .x = 4, .y = 12 });
        try b.lineTo(.{ .x = 12, .y = 12 });
        try b.lineTo(.{ .x = 12, .y = 4 });
        try b.stroke(.{ .color = Color.rgba(0xFF, 0, 0, 0xFF), .width = 4, .join = .miter, .cap = .butt });
        render(.{ .pixels = &pix_miter, .width = 24, .height = 24 }, &dl, font_mod.default_font, 1.0);
    }
    {
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(24, 24);
        var b = dl.beginPath(arena.allocator());
        try b.moveTo(.{ .x = 4, .y = 12 });
        try b.lineTo(.{ .x = 12, .y = 12 });
        try b.lineTo(.{ .x = 12, .y = 4 });
        try b.stroke(.{ .color = Color.rgba(0xFF, 0, 0, 0xFF), .width = 4, .join = .bevel, .cap = .butt });
        render(.{ .pixels = &pix_bevel, .width = 24, .height = 24 }, &dl, font_mod.default_font, 1.0);
    }
    try std.testing.expect(!std.mem.eql(u32, &pix_miter, &pix_bevel));

    var pix_butt = [_]u32{0xFF000000} ** (20 * 12);
    var pix_square = pix_butt;
    {
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(20, 12);
        var b = dl.beginPath(arena.allocator());
        try b.moveTo(.{ .x = 4, .y = 6 });
        try b.lineTo(.{ .x = 16, .y = 6 });
        try b.stroke(.{ .color = Color.rgba(0, 0xFF, 0, 0xFF), .width = 4, .cap = .butt });
        render(.{ .pixels = &pix_butt, .width = 20, .height = 12 }, &dl, font_mod.default_font, 1.0);
    }
    {
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(20, 12);
        var b = dl.beginPath(arena.allocator());
        try b.moveTo(.{ .x = 4, .y = 6 });
        try b.lineTo(.{ .x = 16, .y = 6 });
        try b.stroke(.{ .color = Color.rgba(0, 0xFF, 0, 0xFF), .width = 4, .cap = .square });
        render(.{ .pixels = &pix_square, .width = 20, .height = 12 }, &dl, font_mod.default_font, 1.0);
    }
    try std.testing.expect(!std.mem.eql(u32, &pix_butt, &pix_square));
}

test "path stroke: a closed rectangle has no gap at the start/end join" {
    var pixels = [_]u32{0xFF000000} ** (20 * 20);
    const target = RenderTarget{ .pixels = &pixels, .width = 20, .height = 20 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(20, 20);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 4, .y = 4 });
    try b.lineTo(.{ .x = 16, .y = 4 });
    try b.lineTo(.{ .x = 16, .y = 16 });
    try b.lineTo(.{ .x = 4, .y = 16 });
    try b.close();
    try b.stroke(.{ .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .width = 2, .join = .miter });
    render(target, &dl, font_mod.default_font, 1.0);

    // Mid-edge samples on all four sides, including the first-segment start.
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pathPx(&pixels, 20, 10, 4));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pathPx(&pixels, 20, 16, 10));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pathPx(&pixels, 20, 10, 16));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pathPx(&pixels, 20, 4, 10));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pathPx(&pixels, 20, 4, 4));
}

test "path stroke: a quadratic paints ink (not only the endpoints)" {
    var pixels = [_]u32{0xFF000000} ** (32 * 24);
    const target = RenderTarget{ .pixels = &pixels, .width = 32, .height = 24 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(32, 24);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 2, .y = 20 });
    try b.quadTo(.{ .x = 16, .y = 2 }, .{ .x = 30, .y = 20 });
    try b.stroke(.{ .color = Color.rgba(0, 0xFF, 0, 0xFF), .width = 2, .aa = true });
    render(target, &dl, font_mod.default_font, 1.0);

    var painted: usize = 0;
    for (pixels) |px| {
        if (px != 0xFF000000) painted += 1;
    }
    try std.testing.expect(painted > 20);
    // Mid-curve of (2,20)–(16,2)–(30,20) sits near (16, 11).
    try std.testing.expect(pathPx(&pixels, 32, 16, 11) != 0xFF000000);
}

test "path stroke: second frame allocates nothing (FailingAllocator)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 4, .y = 8 });
    try b.lineTo(.{ .x = 40, .y = 8 });
    try b.lineTo(.{ .x = 40, .y = 40 });
    try b.quadTo(.{ .x = 20, .y = 56 }, .{ .x = 4, .y = 40 });
    try b.close();
    try b.stroke(.{
        .color = Color.rgba(0x40, 0x80, 0xC0, 0xA0),
        .width = 3,
        .join = .miter,
        .cap = .round,
        .aa = true,
    });

    var pixels = [_]u32{0xFF101010} ** (64 * 64);
    const target = RenderTarget{ .pixels = &pixels, .width = 64, .height = 64 };
    render(target, &dl, font_mod.default_font, 1.0);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    dl.alloc = failing.allocator();
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    dl.alloc = std.testing.allocator;
}

test "path stroke: a miter over the limit matches bevel at the corner pixel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const turn: f32 = 160.0 * std.math.rad_per_deg;
    const x2 = 16.0 + 12.0 * @cos(turn);
    const y2 = 12.0 + 12.0 * @sin(turn);

    var pix_limited = [_]u32{0xFF000000} ** (40 * 28);
    var pix_bevel = pix_limited;
    {
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(40, 28);
        var b = dl.beginPath(arena.allocator());
        try b.moveTo(.{ .x = 4, .y = 12 });
        try b.lineTo(.{ .x = 16, .y = 12 });
        try b.lineTo(.{ .x = x2, .y = y2 });
        try b.stroke(.{ .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .width = 4, .join = .miter, .miter_limit = 4 });
        render(.{ .pixels = &pix_limited, .width = 40, .height = 28 }, &dl, font_mod.default_font, 1.0);
    }
    {
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(40, 28);
        var b = dl.beginPath(arena.allocator());
        try b.moveTo(.{ .x = 4, .y = 12 });
        try b.lineTo(.{ .x = 16, .y = 12 });
        try b.lineTo(.{ .x = x2, .y = y2 });
        try b.stroke(.{ .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .width = 4, .join = .bevel, .miter_limit = 4 });
        render(.{ .pixels = &pix_bevel, .width = 40, .height = 28 }, &dl, font_mod.default_font, 1.0);
    }
    try std.testing.expectEqualSlices(u32, &pix_bevel, &pix_limited);
}

fn countOpaqueCol(pixels: []const u32, stride: u32, x: u32, h: u32) usize {
    var n: usize = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        if (pixels[y * stride + x] != 0xFF000000) n += 1;
    }
    return n;
}

fn strokeRightAngle(
    dl: *DrawList,
    arena: std.mem.Allocator,
    join: draw_mod.PathJoin,
    miter_limit: f32,
) !void {
    var b = dl.beginPath(arena);
    try b.moveTo(.{ .x = 8, .y = 24 });
    try b.lineTo(.{ .x = 40, .y = 24 });
    try b.lineTo(.{ .x = 40, .y = 8 });
    try b.stroke(.{
        .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
        .width = 8,
        .join = join,
        .cap = .butt,
        .miter_limit = miter_limit,
        .aa = false,
    });
}

test "path stroke: bevel keeps full width on the inner side of the corner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pixels = [_]u32{0xFF000000} ** (56 * 40);
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(56, 40);
    try strokeRightAngle(&dl, arena.allocator(), .bevel, 4);
    render(.{ .pixels = &pixels, .width = 56, .height = 40 }, &dl, font_mod.default_font, 1.0);

    // Width 8, AA off, centerline y=24 → 8 opaque rows on a straight column.
    const straight = countOpaqueCol(&pixels, 56, 20, 40);
    try std.testing.expectEqual(@as(usize, 8), straight);
    // x=35 is still on the horizontal arm (inner corner is at x=36). A
    // notched inner bevel would drop this count below the straight run.
    try std.testing.expectEqual(straight, countOpaqueCol(&pixels, 56, 35, 40));
}

test "path stroke: a miter that falls back to bevel keeps inner width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pixels = [_]u32{0xFF000000} ** (56 * 40);
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(56, 40);
    // 90° miter ratio is √2; limit 1 forces the bevel fallback.
    try strokeRightAngle(&dl, arena.allocator(), .miter, 1);
    render(.{ .pixels = &pixels, .width = 56, .height = 40 }, &dl, font_mod.default_font, 1.0);

    const straight = countOpaqueCol(&pixels, 56, 20, 40);
    try std.testing.expectEqual(@as(usize, 8), straight);
    try std.testing.expectEqual(straight, countOpaqueCol(&pixels, 56, 35, 40));
}

test "path stroke: a hairline one-point round cap still paints" {
    var pixels = [_]u32{0xFF000000} ** (16 * 16);
    const target = RenderTarget{ .pixels = &pixels, .width = 16, .height = 16 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(16, 16);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = dl.beginPath(arena.allocator());
    try b.moveTo(.{ .x = 8.5, .y = 8.5 });
    try b.stroke(.{
        .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF),
        .width = 0.25,
        .cap = .round,
        .aa = true,
    });
    render(target, &dl, font_mod.default_font, 1.0);

    var painted: usize = 0;
    for (pixels) |px| {
        if (px != 0xFF000000) painted += 1;
    }
    try std.testing.expect(painted > 0);
}

test "path stroke: a closed one-point or two-point contour paints nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pixels = [_]u32{0xFF000000} ** (16 * 16);
    const target = RenderTarget{ .pixels = &pixels, .width = 16, .height = 16 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(16, 16);
    {
        var b = dl.beginPath(arena.allocator());
        try b.moveTo(.{ .x = 8, .y = 8 });
        try b.close();
        try b.stroke(.{ .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .width = 6, .cap = .round });
    }
    {
        var b = dl.beginPath(arena.allocator());
        try b.moveTo(.{ .x = 2, .y = 8 });
        try b.lineTo(.{ .x = 14, .y = 8 });
        try b.close();
        try b.stroke(.{ .color = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .width = 6, .cap = .square });
    }
    render(target, &dl, font_mod.default_font, 1.0);
    for (pixels) |px| {
        try std.testing.expectEqual(@as(u32, 0xFF000000), px);
    }
}

test "rounded render: zero radius is bit-identical to the sharp rectangle route" {
    var sharp_pixels = [_]u32{0xFF102030} ** (32 * 24);
    var rounded_pixels = sharp_pixels;
    const sharp_target = RenderTarget{ .pixels = &sharp_pixels, .width = 32, .height = 24 };
    const rounded_target = RenderTarget{ .pixels = &rounded_pixels, .width = 32, .height = 24 };
    var sharp = DrawList.init(std.testing.allocator);
    defer sharp.deinit();
    sharp.reset(32, 24);
    var rounded = DrawList.init(std.testing.allocator);
    defer rounded.deinit();
    rounded.reset(32, 24);
    const rect = Rect{ .x = 3, .y = 4, .w = 21, .h = 15 };
    const color = Color.rgba(0x90, 0x40, 0xD0, 0x80);
    try sharp.rectFilled(rect, color);
    try sharp.rectOutline(rect, color, 3);
    try rounded.rectFilledEx(rect, color, .{ .radius = 0, .aa = false });
    try rounded.rectOutlineEx(rect, color, 3, .{ .radius = 0, .aa = false });
    render(sharp_target, &sharp, font_mod.default_font, 1.0);
    render(rounded_target, &rounded, font_mod.default_font, 1.0);
    try std.testing.expectEqualSlices(u32, &sharp_pixels, &rounded_pixels);
    try std.testing.expectEqual(@as(u64, 0), rounded.cornerMaskDiagnostics().hits);
    try std.testing.expectEqual(@as(u64, 0), rounded.cornerMaskDiagnostics().misses);
    try std.testing.expectEqual(@as(usize, 0), rounded.path_scratch_pixels);
}

test "rounded fill: corner edge interior clip and translucent seams are correct" {
    const background: u32 = 0xFF102030;
    var pixels = [_]u32{background} ** (32 * 24);
    const target = RenderTarget{ .pixels = &pixels, .width = 32, .height = 24 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(32, 24);
    try dl.pushClip(.{ .x = 4, .y = 3, .w = 20, .h = 16 });
    const color = Color.rgba(0xE0, 0x60, 0x20, 0x80);
    try dl.rectFilledEx(.{ .x = 2, .y = 2, .w = 24, .h = 18 }, color, .{ .radius = 6, .aa = false });
    dl.popClip();
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqual(background, pixels[2 * 32 + 2]);
    try std.testing.expectEqual(background, pixels[4 * 32 + 3]);
    const blended = @as(u32, @bitCast(Color.blend(@bitCast(background), color)));
    try std.testing.expectEqual(blended, pixels[3 * 32 + 10]);
    try std.testing.expectEqual(blended, pixels[6 * 32 + 6]);
    try std.testing.expectEqual(blended, pixels[10 * 32 + 4]);
    try std.testing.expectEqual(blended, pixels[10 * 32 + 12]);
    try std.testing.expectEqual(background, pixels[10 * 32 + 24]);
}

test "rounded fill: radius clamps after scale and tiny rectangles collapse to sharp" {
    try std.testing.expectEqual(@as(u32, 1), clampedDeviceRadius(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, 1, 0.1));
    try std.testing.expectEqual(@as(u32, 5), clampedDeviceRadius(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, 3, 1.5));
    try std.testing.expectEqual(@as(u32, 4), clampedDeviceRadius(.{ .x = 0, .y = 0, .w = 20, .h = 8 }, 99, 2.0));
    try std.testing.expectEqual(@as(u32, 0), clampedDeviceRadius(.{ .x = 0, .y = 0, .w = 20, .h = 1 }, 8, 1.0));
    for ([_]f32{ 1.0, 1.5, 2.0 }) |scale| {
        var pixels = [_]u32{0xFF000000} ** (48 * 48);
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(24, 24);
        try dl.rectFilledEx(.{ .x = 2, .y = 2, .w = 12, .h = 8 }, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .{ .radius = 99 });
        render(.{ .pixels = &pixels, .width = 48, .height = 48 }, &dl, font_mod.default_font, scale);
        try std.testing.expect(dl.cornerMaskDiagnostics().coverage_pixels != 0);
    }

    var tiny_pixels = [_]u32{0xFF000000} ** 8;
    var tiny = DrawList.init(std.testing.allocator);
    defer tiny.deinit();
    tiny.reset(8, 1);
    try tiny.rectFilledEx(.{ .x = 0, .y = 0, .w = 8, .h = 1 }, Color.rgba(0xFF, 0, 0, 0xFF), .{ .radius = 8 });
    render(.{ .pixels = &tiny_pixels, .width = 8, .height = 1 }, &tiny, font_mod.default_font, 1.0);
    const tiny_color: u32 = @bitCast(Color.rgba(0xFF, 0, 0, 0xFF));
    for (tiny_pixels) |pixel| try std.testing.expectEqual(tiny_color, pixel);
    try std.testing.expectEqual(@as(u64, 0), tiny.cornerMaskDiagnostics().misses);
}

test "rounded outline: thickness zero through filled collapse keep the center contract" {
    for ([_]u32{ 0, 3, 6, 9, 12 }) |thickness| {
        var pixels = [_]u32{0xFF000000} ** (32 * 32);
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(32, 32);
        try dl.rectOutlineEx(.{ .x = 4, .y = 5, .w = 24, .h = 20 }, Color.rgba(0x40, 0xC0, 0xFF, 0xFF), thickness, .{ .radius = 6 });
        render(.{ .pixels = &pixels, .width = 32, .height = 32 }, &dl, font_mod.default_font, 1.0);
        try std.testing.expect(pixels[5 * 32 + 16] != 0xFF000000);
        if (thickness < 10) {
            try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[15 * 32 + 16]);
        } else {
            try std.testing.expect(pixels[15 * 32 + 16] != 0xFF000000);
        }
    }
}

test "rounded render: circles equal the same device bounding rounded square" {
    var circle_pixels = [_]u32{0xFF111111} ** (40 * 40);
    var square_pixels = circle_pixels;
    var circle = DrawList.init(std.testing.allocator);
    defer circle.deinit();
    circle.reset(40, 40);
    var square = DrawList.init(std.testing.allocator);
    defer square.deinit();
    square.reset(40, 40);
    const color = Color.rgba(0x80, 0xD0, 0x40, 0xB0);
    try circle.circleFilled(.{ .x = 20, .y = 20 }, 10, color, .{});
    try circle.circleOutline(.{ .x = 20, .y = 20 }, 8, color, 3, .{ .aa = false });
    try square.rectFilledEx(.{ .x = 10, .y = 10, .w = 20, .h = 20 }, color, .{ .radius = 10 });
    try square.rectOutlineEx(.{ .x = 12, .y = 12, .w = 16, .h = 16 }, color, 3, .{ .radius = 8, .aa = false });
    render(.{ .pixels = &circle_pixels, .width = 40, .height = 40 }, &circle, font_mod.default_font, 1.0);
    render(.{ .pixels = &square_pixels, .width = 40, .height = 40 }, &square, font_mod.default_font, 1.0);
    try std.testing.expect(circle_pixels[20 * 40 + 20] != 0xFF111111);
    try std.testing.expectEqualSlices(u32, &circle_pixels, &square_pixels);
}

test "rounded render: a warm second render allocates nothing and hits retained masks" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    try dl.rectFilledEx(.{ .x = 4, .y = 4, .w = 50, .h = 30 }, Color.rgba(0x20, 0x80, 0xE0, 0xFF), .{ .radius = 9 });
    try dl.rectOutlineEx(.{ .x = 6, .y = 38, .w = 48, .h = 22 }, Color.rgba(0xE0, 0x80, 0x20, 0xA0), 3, .{ .radius = 8 });
    var pixels = [_]u32{0xFF101010} ** (64 * 64);
    const target = RenderTarget{ .pixels = &pixels, .width = 64, .height = 64 };
    render(target, &dl, font_mod.default_font, 1.0);
    const cold = dl.cornerMaskDiagnostics();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    dl.alloc = failing.allocator();
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    try std.testing.expect(dl.cornerMaskDiagnostics().hits > cold.hits);
    dl.alloc = std.testing.allocator;
}

test "rounded render: reset retains masks and AA variants reuse the same entry" {
    var pixels = [_]u32{0xFF000000} ** (32 * 32);
    const target = RenderTarget{ .pixels = &pixels, .width = 32, .height = 32 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(32, 32);
    try dl.rectFilledEx(.{ .x = 2, .y = 2, .w = 24, .h = 20 }, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .{ .radius = 7 });
    render(target, &dl, font_mod.default_font, 1.0);
    const first = dl.cornerMaskDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), first.entries);
    dl.reset(32, 32);
    try dl.rectFilledEx(.{ .x = 2, .y = 2, .w = 24, .h = 20 }, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .{ .radius = 7, .aa = false });
    render(target, &dl, font_mod.default_font, 1.0);
    const second = dl.cornerMaskDiagnostics();
    try std.testing.expectEqual(first.allocations, second.allocations);
    try std.testing.expect(second.hits > first.hits);
}

test "rounded render: an oversized mask uses bounded visible-band scratch without retention" {
    var pixels = [_]u32{0xFF000000} ** (16 * 16);
    const target = RenderTarget{ .pixels = &pixels, .width = 16, .height = 16 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(16, 16);
    try dl.rectFilledEx(.{ .x = 0, .y = 0, .w = 4098, .h = 4098 }, Color.rgba(0xFF, 0xFF, 0xFF, 0xFF), .{ .radius = 2049 });
    try dl.rectOutlineEx(.{ .x = 0, .y = 0, .w = 4098, .h = 4098 }, Color.rgba(0xFF, 0, 0, 0x80), 5, .{ .radius = 2049 });
    render(target, &dl, font_mod.default_font, 1.0);
    const diagnostics = dl.cornerMaskDiagnostics();
    try std.testing.expectEqual(@as(usize, 0), diagnostics.entries);
    try std.testing.expect(diagnostics.coverage_pixels != 0);
    try std.testing.expect(dl.path_scratch_peak_bytes <= draw_mod.path_scratch_limit_bytes);
}

test "rounded render: zero-radius circles are no-ops without cache activity" {
    var pixels = [_]u32{0xFF123456} ** (8 * 8);
    const before = pixels;
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(8, 8);
    try dl.circleFilled(.{ .x = 4, .y = 4 }, 0, Color.rgba(0xFF, 0, 0, 0xFF), .{});
    try dl.circleOutline(.{ .x = 4, .y = 4 }, 0, Color.rgba(0, 0xFF, 0, 0xFF), 0, .{});
    render(.{ .pixels = &pixels, .width = 8, .height = 8 }, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqualSlices(u32, &before, &pixels);
    try std.testing.expectEqual(@as(u64, 0), dl.cornerMaskDiagnostics().misses);
}

test "rounded render: SIMD and scalar corner coverage are framebuffer-identical" {
    var simd_pixels = [_]u32{0xFF17202A} ** (64 * 48);
    var scalar_pixels = simd_pixels;
    var simd = DrawList.init(std.testing.allocator);
    defer simd.deinit();
    var scalar = DrawList.init(std.testing.allocator);
    defer scalar.deinit();
    simd.reset(64, 48);
    scalar.reset(64, 48);
    const rect = Rect{ .x = 3, .y = 5, .w = 44, .h = 30 };
    const color = Color.rgba(0x50, 0xB0, 0xF0, 0x91);
    drawRoundedFilledDevice(.{ .pixels = &simd_pixels, .width = 64, .height = 48 }, &simd, rect, color, 11, true, .{ .x = 0, .y = 0, .w = 64, .h = 48 }, 1.0, true);
    drawRoundedOutlineDevice(.{ .pixels = &simd_pixels, .width = 64, .height = 48 }, &simd, .{ .x = 18, .y = 12, .w = 40, .h = 30 }, color, 5, 12, false, .{ .x = 0, .y = 0, .w = 64, .h = 48 }, 1.0, true);
    drawRoundedFilledDevice(.{ .pixels = &scalar_pixels, .width = 64, .height = 48 }, &scalar, rect, color, 11, true, .{ .x = 0, .y = 0, .w = 64, .h = 48 }, 1.0, false);
    drawRoundedOutlineDevice(.{ .pixels = &scalar_pixels, .width = 64, .height = 48 }, &scalar, .{ .x = 18, .y = 12, .w = 40, .h = 30 }, color, 5, 12, false, .{ .x = 0, .y = 0, .w = 64, .h = 48 }, 1.0, false);
    try std.testing.expectEqualSlices(u32, &simd_pixels, &scalar_pixels);
}

test "shadow render: SIMD and scalar nine-slice coverage are framebuffer-identical and warm" {
    var simd_pixels = [_]u32{0xFF17202A} ** (96 * 64);
    var scalar_pixels = simd_pixels;
    var simd = DrawList.init(std.testing.allocator);
    defer simd.deinit();
    var scalar = DrawList.init(std.testing.allocator);
    defer scalar.deinit();
    simd.reset(96, 64);
    scalar.reset(96, 64);
    const rect = Rect{ .x = 14, .y = 12, .w = 58, .h = 32 };
    const clip = Rect{ .x = 0, .y = 0, .w = 96, .h = 64 };
    const options: draw_mod.ShadowOptions = .{ .radius = 12, .blur = 8, .offset = .{ .x = 3, .y = 4 } };
    const color = Color.rgba(0x00, 0x00, 0x00, 0xA0);
    const simd_target = RenderTarget{ .pixels = &simd_pixels, .width = 96, .height = 64 };
    const scalar_target = RenderTarget{ .pixels = &scalar_pixels, .width = 96, .height = 64 };
    drawShadow(simd_target, &simd, rect, color, options, clip, 1.0, true);
    const first_pixels = simd_pixels;
    try std.testing.expect(first_pixels[32 * 96 + 40] != 0xFF17202A);
    drawShadow(scalar_target, &scalar, rect, color, options, clip, 1.0, false);
    try std.testing.expectEqualSlices(u32, &first_pixels, &scalar_pixels);

    const cold = simd.shadowMaskDiagnostics();
    drawShadow(simd_target, &simd, rect, color, options, clip, 1.0, true);
    const warm = simd.shadowMaskDiagnostics();
    try std.testing.expectEqual(cold.evaluations, warm.evaluations);
    try std.testing.expectEqual(cold.allocations, warm.allocations);
    try std.testing.expect(warm.hits > cold.hits);
    try std.testing.expect(warm.blit_pixels > cold.blit_pixels);
}

test "shadow render: fractional scale and clip boundaries use the retained key" {
    var pixels = [_]u32{0xFF202020} ** (96 * 64);
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 48);
    try dl.shadow(.{ .x = 4, .y = 4, .w = 28, .h = 20 }, Color.rgba(0, 0, 0, 0x90), .{
        .radius = 6,
        .blur = 4,
        .offset = .{ .x = 2, .y = -1 },
    });
    const target = RenderTarget{ .pixels = &pixels, .width = 96, .height = 64 };
    render(target, &dl, font_mod.default_font, 1.5);
    const first = dl.shadowMaskDiagnostics();
    render(target, &dl, font_mod.default_font, 1.5);
    const second = dl.shadowMaskDiagnostics();
    try std.testing.expectEqual(@as(u64, 1), first.evaluations);
    try std.testing.expectEqual(first.evaluations, second.evaluations);
    try std.testing.expectEqual(first.allocations, second.allocations);
    try std.testing.expect(second.hits > first.hits);
}

/// Read one pixel of a test target by signed coordinates, so a fixture can assert
/// on both sides of an edge without casting at every call site.
fn pixelAt(pixels: []const u32, width: usize, x: i32, y: i32) u32 {
    return pixels[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))];
}

test "shadow render: the shadow lands on the rectangle the caller physicalized" {
    // A zero radius and a zero blur make the mask a single fully opaque sample, so
    // the shadow covers exactly the rectangle it was given. Its edges are then an
    // exact oracle for where the shadow landed and how large it is.
    const background: u32 = 0xFF202020;
    const color = Color.rgba(0, 0, 0, 0xFF);
    const ink: u32 = @bitCast(color);
    // The rectangle is (9, 7, 20, 14): at 1.5 every edge lands on a half pixel, so
    // the expected values below hold only under the floor rule and a round or ceil
    // would miss them.
    const cases = [_]struct { scale: f32, x0: i32, y0: i32, x1: i32, y1: i32 }{
        .{ .scale = 1.0, .x0 = 9, .y0 = 7, .x1 = 29, .y1 = 21 },
        .{ .scale = 1.5, .x0 = 13, .y0 = 10, .x1 = 43, .y1 = 31 },
        .{ .scale = 2.0, .x0 = 18, .y0 = 14, .x1 = 58, .y1 = 42 },
    };
    for (cases) |c| {
        var pixels = [_]u32{background} ** (128 * 96);
        var dl = DrawList.init(std.testing.allocator);
        defer dl.deinit();
        dl.reset(64, 48);
        try dl.shadow(.{ .x = 9, .y = 7, .w = 20, .h = 14 }, color, .{});
        const target = RenderTarget{ .pixels = &pixels, .width = 128, .height = 96 };
        render(target, &dl, font_mod.default_font, c.scale);

        try std.testing.expectEqual(ink, pixelAt(&pixels, 128, c.x0, c.y0));
        try std.testing.expectEqual(ink, pixelAt(&pixels, 128, c.x1 - 1, c.y0));
        try std.testing.expectEqual(ink, pixelAt(&pixels, 128, c.x0, c.y1 - 1));
        try std.testing.expectEqual(ink, pixelAt(&pixels, 128, c.x1 - 1, c.y1 - 1));
        try std.testing.expectEqual(ink, pixelAt(&pixels, 128, @divTrunc(c.x0 + c.x1, 2), @divTrunc(c.y0 + c.y1, 2)));

        try std.testing.expectEqual(background, pixelAt(&pixels, 128, c.x0 - 1, c.y0));
        try std.testing.expectEqual(background, pixelAt(&pixels, 128, c.x0, c.y0 - 1));
        try std.testing.expectEqual(background, pixelAt(&pixels, 128, c.x1, c.y1 - 1));
        try std.testing.expectEqual(background, pixelAt(&pixels, 128, c.x1 - 1, c.y1));
    }
}

test "shadow render: the offset is physicalized once" {
    const background: u32 = 0xFF202020;
    const color = Color.rgba(0, 0, 0, 0xFF);
    const ink: u32 = @bitCast(color);
    var pixels = [_]u32{background} ** (128 * 96);
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 48);
    try dl.shadow(.{ .x = 10, .y = 8, .w = 20, .h = 12 }, color, .{ .offset = .{ .x = 4, .y = -2 } });
    const target = RenderTarget{ .pixels = &pixels, .width = 128, .height = 96 };
    render(target, &dl, font_mod.default_font, 2.0);

    // The rectangle physicalizes to (20, 16, 40, 24) and the offset to (8, -4),
    // which puts the shadow at (28, 12) through (68, 36) exclusive.
    try std.testing.expectEqual(ink, pixelAt(&pixels, 128, 28, 12));
    try std.testing.expectEqual(ink, pixelAt(&pixels, 128, 67, 35));
    try std.testing.expectEqual(background, pixelAt(&pixels, 128, 27, 12));
    try std.testing.expectEqual(background, pixelAt(&pixels, 128, 28, 11));
    try std.testing.expectEqual(background, pixelAt(&pixels, 128, 68, 35));
    try std.testing.expectEqual(background, pixelAt(&pixels, 128, 67, 36));
}

test "shadow render: the radius, blur, offset and clip are each physicalized once" {
    // A soft shadow has no crisp silhouette to compare against, but the region it
    // is allowed to touch is exact: the physical rectangle displaced by the offset,
    // grown by the blur, and intersected with the physical clip. Converting any of
    // those a second time moves or widens that region, so asserting that nothing
    // outside it changed catches a repeated conversion without depending on the
    // mask's coverage profile.
    const background: u32 = 0xFF202020;
    const scale: f32 = 1.5;
    const logical_rect = Rect{ .x = 9, .y = 7, .w = 20, .h = 14 };
    const logical_clip = Rect{ .x = 6, .y = 5, .w = 30, .h = 24 };
    const options: draw_mod.ShadowOptions = .{ .radius = 6, .blur = 4, .offset = .{ .x = -3, .y = 5 } };

    var pixels = [_]u32{background} ** (128 * 96);
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 48);
    try dl.pushClip(logical_clip);
    try dl.shadow(logical_rect, Color.rgba(0, 0, 0, 0xC0), options);
    dl.popClip();
    const target = RenderTarget{ .pixels = &pixels, .width = 128, .height = 96 };
    render(target, &dl, font_mod.default_font, scale);

    const base = scaleRect(logical_rect, scale);
    const blur = scaleBlurUnclamped(options.blur, scale);
    const offset = scalePoint(options.offset, scale);
    const outer = Rect{
        .x = base.x + offset.x - @as(i32, @intCast(blur)),
        .y = base.y + offset.y - @as(i32, @intCast(blur)),
        .w = base.w + blur * 2,
        .h = base.h + blur * 2,
    };
    const allowed = clipRect(outer, scaleRect(logical_clip, scale), target);
    try std.testing.expect(!allowed.isEmpty());

    var touched: usize = 0;
    for (0..96) |y| {
        for (0..128) |x| {
            if (pixels[y * 128 + x] == background) continue;
            touched += 1;
            const px: i32 = @intCast(x);
            const py: i32 = @intCast(y);
            try std.testing.expect(px >= allowed.x and px < allowed.x + @as(i32, @intCast(allowed.w)));
            try std.testing.expect(py >= allowed.y and py < allowed.y + @as(i32, @intCast(allowed.h)));
        }
    }
    // The bound is not satisfied by painting nothing at all.
    try std.testing.expect(touched > 0);
}

test "shadow render: zero radius and zero blur use the non-analytic cached route" {
    var pixels = [_]u32{0xFF202020} ** (48 * 32);
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(48, 32);
    try dl.shadow(.{ .x = 8, .y = 6, .w = 24, .h = 16 }, Color.rgba(0, 0, 0, 0xA0), .{});
    render(.{ .pixels = &pixels, .width = 48, .height = 32 }, &dl, font_mod.default_font, 1.0);
    const diagnostics = dl.shadowMaskDiagnostics();
    try std.testing.expectEqual(@as(u64, 1), diagnostics.evaluations);
    try std.testing.expect(diagnostics.blit_pixels > 0);
    try std.testing.expect(pixels[6 * 48 + 8] != 0xFF202020);
}

test "shadow render: a tree without shadow commands does not touch the shadow cache" {
    var pixels = [_]u32{0xFF202020} ** (32 * 24);
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(32, 24);
    try dl.rectFilled(.{ .x = 2, .y = 2, .w = 12, .h = 8 }, Color.rgba(0x40, 0x80, 0xC0, 0xFF));
    render(.{ .pixels = &pixels, .width = 32, .height = 24 }, &dl, font_mod.default_font, 1.0);
    const diagnostics = dl.shadowMaskDiagnostics();
    try std.testing.expectEqual(@as(u64, 0), diagnostics.evaluations);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.hits);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.misses);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.allocations);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.blit_pixels);
}

test "shadow render: DrawList reset retains masks until the explicit cache reset" {
    var pixels = [_]u32{0xFF202020} ** (48 * 32);
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    const rect = Rect{ .x = 8, .y = 6, .w = 24, .h = 16 };
    const clip = Rect{ .x = 0, .y = 0, .w = 48, .h = 32 };
    const color = Color.rgba(0, 0, 0, 0xA0);
    const target = RenderTarget{ .pixels = &pixels, .width = 48, .height = 32 };

    dl.reset(48, 32);
    drawShadow(target, &dl, rect, color, .{ .radius = 6, .blur = 4 }, clip, 1.0, true);
    const cold = dl.shadowMaskDiagnostics();
    dl.reset(48, 32);
    drawShadow(target, &dl, rect, color, .{ .radius = 6, .blur = 4 }, clip, 1.0, true);
    const warm = dl.shadowMaskDiagnostics();
    try std.testing.expectEqual(@as(u64, 1), cold.evaluations);
    try std.testing.expectEqual(cold.evaluations, warm.evaluations);
    try std.testing.expect(warm.hits > cold.hits);
    try std.testing.expect(warm.retained_bytes > 0);

    dl.resetShadowCache();
    const cleared = dl.shadowMaskDiagnostics();
    try std.testing.expectEqual(@as(usize, 0), cleared.entries);
    try std.testing.expectEqual(@as(usize, 0), cleared.retained_bytes);
}

test "gradient render: vertical horizontal diagonal radial and rounded coverage" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    try dl.rectFilledPaint(.{ .x = 0, .y = 0, .w = 16, .h = 16 }, .{ .linear = .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 0, .y = 16 },
        .start_color = Color.rgba(0, 0, 0, 255),
        .end_color = Color.rgba(255, 0, 0, 255),
    } });
    try dl.rectFilledPaint(.{ .x = 16, .y = 0, .w = 16, .h = 16 }, .{ .linear = .{
        .start = .{ .x = 16, .y = 0 },
        .end = .{ .x = 32, .y = 0 },
        .start_color = Color.rgba(0, 0, 0, 255),
        .end_color = Color.rgba(0, 255, 0, 255),
    } });
    try dl.rectFilledPaint(.{ .x = 32, .y = 0, .w = 16, .h = 16 }, .{ .linear = .{
        .start = .{ .x = 32, .y = 0 },
        .end = .{ .x = 48, .y = 16 },
        .start_color = Color.rgba(0, 0, 0, 255),
        .end_color = Color.rgba(0, 0, 255, 255),
    } });
    try dl.rectFilledPaintEx(.{ .x = 0, .y = 20, .w = 24, .h = 24 }, .{ .radial = .{
        .center = .{ .x = 12, .y = 32 },
        .radius = 12,
        .inner_color = Color.rgba(255, 255, 255, 255),
        .outer_color = Color.rgba(0, 0, 0, 255),
    } }, .{ .radius = 6 });
    try dl.rectFilledPaint(.{ .x = 28, .y = 20, .w = 20, .h = 20 }, .{ .linear = .{
        .start = .{ .x = 28, .y = 20 },
        .end = .{ .x = 48, .y = 20 },
        .start_color = Color.rgba(255, 0, 0, 128),
        .end_color = Color.rgba(0, 0, 255, 128),
    } });
    var pixels = [_]u32{0xFF202020} ** (64 * 64);
    render(.{ .pixels = &pixels, .width = 64, .height = 64 }, &dl, font_mod.default_font, 1.0);
    try std.testing.expect(@as(u32, @bitCast(Color.rgba(0, 0, 0, 255))) != pixels[15 * 64]);
    try std.testing.expectEqual(@as(u32, 0xFF202020), pixels[20 * 64]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[32 * 64 + 12]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[20 * 64 + 12]);
    try std.testing.expect(pixels[12 * 64 + 12] != pixels[32 * 64 + 12]);
    try std.testing.expect(pixels[32 * 64 + 12] != pixels[32 * 64 + 36]);
}

test "gradient render: SIMD and scalar paths are framebuffer-identical" {
    var simd = DrawList.init(std.testing.allocator);
    defer simd.deinit();
    var scalar = DrawList.init(std.testing.allocator);
    defer scalar.deinit();
    simd.reset(37, 29);
    scalar.reset(37, 29);
    const paint: Paint = .{ .linear = .{
        .start = .{ .x = -3, .y = 2 },
        .end = .{ .x = 34, .y = 27 },
        .start_color = Color.rgba(20, 40, 80, 120),
        .end_color = Color.rgba(220, 180, 140, 230),
    } };
    try simd.rectFilledPaintEx(.{ .x = -2, .y = 1, .w = 37, .h = 27 }, paint, .{ .radius = 7 });
    try scalar.rectFilledPaintEx(.{ .x = -2, .y = 1, .w = 37, .h = 27 }, paint, .{ .radius = 7 });
    var a = [_]u32{0xFF102030} ** (37 * 29);
    var b = a;
    render(.{ .pixels = &a, .width = 37, .height = 29 }, &simd, font_mod.default_font, 1.0);
    render(.{ .pixels = &b, .width = 37, .height = 29 }, &scalar, font_mod.default_font, 1.0);
    try std.testing.expectEqualSlices(u32, &b, &a);
}

test "gradient render: warm render performs no retained-scratch allocation" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(32, 24);
    try dl.rectFilledPaintEx(.{ .x = 0, .y = 0, .w = 32, .h = 24 }, .{ .radial = .{
        .center = .{ .x = 16, .y = 12 },
        .radius = 16,
        .inner_color = Color.rgba(255, 255, 255, 255),
        .outer_color = Color.rgba(0, 0, 0, 255),
    } }, .{ .radius = 6 });
    var pixels = [_]u32{0xFF000000} ** (32 * 24);
    const target = RenderTarget{ .pixels = &pixels, .width = 32, .height = 24 };
    render(target, &dl, font_mod.default_font, 1.0);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    dl.alloc = failing.allocator();
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    dl.alloc = std.testing.allocator;
}

test "gradient render: solid warm path does not build gradient scratch" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(24, 18);
    try dl.rectFilled(.{ .x = 2, .y = 3, .w = 16, .h = 10 }, Color.rgba(40, 80, 120, 255));
    var pixels = [_]u32{0xFF000000} ** (24 * 18);
    const target = RenderTarget{ .pixels = &pixels, .width = 24, .height = 18 };
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqual(@as(usize, 0), dl.linear_gradient_columns.len);
    try std.testing.expectEqual(@as(usize, 0), dl.radial_gradient_lut.len);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    dl.alloc = failing.allocator();
    render(target, &dl, font_mod.default_font, 1.0);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), dl.linear_gradient_columns.len);
    try std.testing.expectEqual(@as(usize, 0), dl.radial_gradient_lut.len);
    dl.alloc = std.testing.allocator;
}

test "gradient render: scaled dispatch uses physical gradient coordinates" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(12, 12);
    try dl.rectFilledPaint(.{ .x = 1, .y = 1, .w = 6, .h = 6 }, .{ .linear = .{
        .start = .{ .x = 1, .y = 1 },
        .end = .{ .x = 7, .y = 1 },
        .start_color = Color.rgba(255, 0, 0, 255),
        .end_color = Color.rgba(0, 0, 255, 255),
    } });
    var pixels = [_]u32{0xFF202020} ** (18 * 18);
    render(.{ .pixels = &pixels, .width = 18, .height = 18 }, &dl, font_mod.default_font, 1.5);
    try std.testing.expect(pixels[2 * 18 + 2] != 0xFF202020);
    try std.testing.expect(pixels[2 * 18 + 8] != pixels[8 * 18 + 2]);
}

// ── render input domain ────────────────────────────────────────────

test "scaleWithinDomain: rejects values outside (0, MAX_SCALE]" {
    try std.testing.expect(scaleWithinDomain(MAX_SCALE));
    try std.testing.expect(scaleWithinDomain(1.0));
    try std.testing.expect(scaleWithinDomain(2.0));
    try std.testing.expect(!scaleWithinDomain(0.0));
    try std.testing.expect(!scaleWithinDomain(-1.0));
    try std.testing.expect(!scaleWithinDomain(std.math.nan(f32)));
    try std.testing.expect(!scaleWithinDomain(std.math.inf(f32)));
    try std.testing.expect(!scaleWithinDomain(-std.math.inf(f32)));
    try std.testing.expect(!scaleWithinDomain(MAX_SCALE * 2.0));
}

test "cmdWithinDomain: rejects coordinates, extents, thicknesses, and non-finite path values outside the domain" {
    const col = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    const ok_rect = Rect{ .x = 0, .y = 0, .w = 8, .h = 8 };
    const ok_pt = Vec2{ .x = 0, .y = 0 };
    const img = [_]u32{0xFFFFFFFF};
    const ok_path_pts = [_]draw_mod.Vec2f{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 } };
    const ok_path_verbs = [_]draw_mod.PathVerb{ .move, .line };

    try std.testing.expect(cmdWithinDomain(.{ .rect_filled = .{ .rect = ok_rect, .paint = .{ .solid = col }, .clip = ok_rect } }));
    try std.testing.expect(cmdWithinDomain(.{ .rect_filled = .{ .rect = ok_rect, .paint = .{ .linear = .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 8, .y = 0 },
        .start_color = col,
        .end_color = col,
    } }, .clip = ok_rect } }));
    try std.testing.expect(cmdWithinDomain(.{ .rect_filled = .{ .rect = ok_rect, .paint = .{ .radial = .{
        .center = .{ .x = 4, .y = 4 },
        .radius = 4,
        .inner_color = col,
        .outer_color = col,
    } }, .clip = ok_rect } }));
    try std.testing.expect(cmdWithinDomain(.{ .rect_outline = .{ .rect = ok_rect, .color = col, .thickness = geom.MAX_THICKNESS, .clip = ok_rect } }));
    try std.testing.expect(cmdWithinDomain(.{ .line = .{ .p0 = ok_pt, .p1 = ok_pt, .color = col, .thickness = 1, .clip = ok_rect } }));
    try std.testing.expect(cmdWithinDomain(.{ .text = .{ .pos = ok_pt, .text = "A", .color = col, .clip = ok_rect } }));
    try std.testing.expect(cmdWithinDomain(.{ .image = .{ .rect = ok_rect, .pixels = &img, .src_w = 1, .src_h = 1, .clip = ok_rect } }));
    try std.testing.expect(cmdWithinDomain(.{ .path = .{
        .verbs = &ok_path_verbs,
        .points = &ok_path_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = ok_rect,
        .stroke = .{ .width = 1, .join = .miter, .cap = .butt, .miter_limit = 4 },
    } }));

    try std.testing.expect(!cmdWithinDomain(.{ .rect_filled = .{
        .rect = .{ .x = geom.MAX_COORD + 1, .y = 0, .w = 1, .h = 1 },
        .paint = .{ .solid = col },
        .clip = ok_rect,
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .rect_filled = .{
        .rect = .{ .x = geom.MIN_COORD - 1, .y = 0, .w = 1, .h = 1 },
        .paint = .{ .solid = col },
        .clip = ok_rect,
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .rect_filled = .{
        .rect = .{ .x = 0, .y = 0, .w = geom.MAX_EXTENT + 1, .h = 1 },
        .paint = .{ .solid = col },
        .clip = ok_rect,
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .rect_filled = .{
        .rect = ok_rect,
        .paint = .{ .linear = .{
            .start = .{ .x = 3, .y = 3 },
            .end = .{ .x = 3, .y = 3 },
            .start_color = col,
            .end_color = col,
        } },
        .clip = ok_rect,
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .rect_filled = .{
        .rect = ok_rect,
        .paint = .{ .radial = .{
            .center = .{ .x = 3, .y = 3 },
            .radius = 0,
            .inner_color = col,
            .outer_color = col,
        } },
        .clip = ok_rect,
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .rect_outline = .{
        .rect = ok_rect,
        .color = col,
        .thickness = geom.MAX_THICKNESS + 1,
        .clip = ok_rect,
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .line = .{
        .p0 = .{ .x = geom.MAX_COORD + 1, .y = 0 },
        .p1 = ok_pt,
        .color = col,
        .thickness = 1,
        .clip = ok_rect,
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .text = .{
        .pos = ok_pt,
        .text = "A",
        .color = col,
        .clip = .{ .x = 0, .y = 0, .w = geom.MAX_EXTENT + 1, .h = 1 },
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .image = .{
        .rect = ok_rect,
        .pixels = &img,
        .src_w = 1,
        .src_h = 1,
        .clip = .{ .x = geom.MIN_COORD - 1, .y = 0, .w = 1, .h = 1 },
    } }));

    const nan_pts = [_]draw_mod.Vec2f{.{ .x = std.math.nan(f32), .y = 0 }};
    try std.testing.expect(!cmdWithinDomain(.{ .path = .{
        .verbs = &.{.move},
        .points = &nan_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = ok_rect,
    } }));
    const inf_pts = [_]draw_mod.Vec2f{.{ .x = std.math.inf(f32), .y = 0 }};
    try std.testing.expect(!cmdWithinDomain(.{ .path = .{
        .verbs = &.{.move},
        .points = &inf_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = ok_rect,
    } }));
    const oob_pts = [_]draw_mod.Vec2f{.{ .x = @floatFromInt(geom.MAX_COORD + 1), .y = 0 }};
    try std.testing.expect(!cmdWithinDomain(.{ .path = .{
        .verbs = &.{.move},
        .points = &oob_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = ok_rect,
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .path = .{
        .verbs = &ok_path_verbs,
        .points = &ok_path_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = ok_rect,
        .stroke = .{ .width = std.math.nan(f32), .join = .miter, .cap = .butt, .miter_limit = 4 },
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .path = .{
        .verbs = &ok_path_verbs,
        .points = &ok_path_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = ok_rect,
        .stroke = .{ .width = std.math.inf(f32), .join = .miter, .cap = .butt, .miter_limit = 4 },
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .path = .{
        .verbs = &ok_path_verbs,
        .points = &ok_path_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = ok_rect,
        .stroke = .{ .width = 1, .join = .miter, .cap = .butt, .miter_limit = std.math.nan(f32) },
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .path = .{
        .verbs = &ok_path_verbs,
        .points = &ok_path_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = ok_rect,
        .stroke = .{ .width = 1, .join = .miter, .cap = .butt, .miter_limit = std.math.inf(f32) },
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .path = .{
        .verbs = &ok_path_verbs,
        .points = &ok_path_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = ok_rect,
        .stroke = .{ .width = 0, .join = .miter, .cap = .butt, .miter_limit = 4 },
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .path = .{
        .verbs = &ok_path_verbs,
        .points = &ok_path_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = ok_rect,
        .stroke = .{ .width = -1, .join = .miter, .cap = .butt, .miter_limit = 4 },
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .path = .{
        .verbs = &ok_path_verbs,
        .points = &ok_path_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = ok_rect,
        .stroke = .{ .width = draw_mod.path_stroke_width_max + 1, .join = .miter, .cap = .butt, .miter_limit = 4 },
    } }));
    try std.testing.expect(!cmdWithinDomain(.{ .path = .{
        .verbs = &ok_path_verbs,
        .points = &ok_path_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = ok_rect,
        .stroke = .{ .width = 1, .join = .miter, .cap = .butt, .miter_limit = 0 },
    } }));
}

test "render: domain maxima at MAX_SCALE do not panic" {
    var pixels = [_]u32{0xFF000000} ** (32 * 32);
    const target = RenderTarget{ .pixels = &pixels, .width = 32, .height = 32 };
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    dl.reset(32, 32);

    const max_c = geom.MAX_COORD;
    const min_c = geom.MIN_COORD;
    const max_e = geom.MAX_EXTENT;
    const max_t = geom.MAX_THICKNESS;
    const col = Color.rgba(0xFF, 0xFF, 0xFF, 0xFF);
    const far_pos = Rect{ .x = max_c, .y = max_c, .w = max_e, .h = max_e };
    const far_neg = Rect{ .x = min_c, .y = min_c, .w = max_e, .h = max_e };
    const cover = Rect{ .x = 0, .y = 0, .w = max_e, .h = max_e };
    const img = [_]u32{0xFFFFFFFF};

    try dl.cmds.append(dl.alloc, .{ .rect_filled = .{ .rect = far_pos, .paint = .{ .solid = col }, .clip = far_pos } });
    try dl.cmds.append(dl.alloc, .{ .rect_outline = .{ .rect = far_neg, .color = col, .thickness = max_t, .clip = far_neg } });
    try dl.cmds.append(dl.alloc, .{ .line = .{
        .p0 = .{ .x = max_c, .y = min_c },
        .p1 = .{ .x = max_c, .y = max_c },
        .color = col,
        .thickness = max_t,
        .clip = far_pos,
    } });
    try dl.cmds.append(dl.alloc, .{ .text = .{
        .pos = .{ .x = max_c, .y = max_c },
        .text = "A",
        .color = col,
        .clip = far_pos,
    } });
    try dl.cmds.append(dl.alloc, .{ .image = .{
        .rect = far_pos,
        .pixels = &img,
        .src_w = 1,
        .src_h = 1,
        .clip = far_pos,
    } });

    const fill_pts = [_]draw_mod.Vec2f{
        .{ .x = @floatFromInt(max_c), .y = @floatFromInt(max_c) },
        .{ .x = @floatFromInt(max_c - 8), .y = @floatFromInt(max_c) },
        .{ .x = @floatFromInt(max_c), .y = @floatFromInt(max_c - 8) },
    };
    const fill_verbs = [_]draw_mod.PathVerb{ .move, .line, .line, .close };
    try dl.cmds.append(dl.alloc, .{ .path = .{
        .verbs = &fill_verbs,
        .points = &fill_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = cover,
        .stroke = null,
    } });

    const stroke_pts = [_]draw_mod.Vec2f{
        .{ .x = @floatFromInt(min_c), .y = @floatFromInt(min_c + 16) },
        .{ .x = @floatFromInt(min_c + 16), .y = @floatFromInt(min_c + 16) },
        .{ .x = @floatFromInt(min_c + 16), .y = @floatFromInt(min_c) },
    };
    const stroke_verbs = [_]draw_mod.PathVerb{ .move, .line, .line };
    try dl.cmds.append(dl.alloc, .{ .path = .{
        .verbs = &stroke_verbs,
        .points = &stroke_pts,
        .color = col,
        .winding = .nonzero,
        .aa = true,
        .clip = cover,
        .stroke = .{
            .width = @floatFromInt(max_t),
            .join = .miter,
            .cap = .butt,
            .miter_limit = 4.0,
        },
    } });

    render(target, &dl, font_mod.default_font, MAX_SCALE);
}

// ============================================================================
// renderProfiled tests
//
// A scripted clock is used rather than a real one, so these assert what the profiler
// records rather than how fast the machine is. A wall clock would make them flaky and,
// worse, would let a profiler that always reports zero pass on a fast machine.
// ============================================================================

var test_clock_now: f64 = 0;
var test_clock_step: f64 = 0;

fn testClock() f64 {
    const now = test_clock_now;
    test_clock_now += test_clock_step;
    return now;
}

fn testTarget(pixels: []u32, w: u32, h: u32) RenderTarget {
    return .{ .pixels = pixels, .width = w, .height = h };
}

/// One command of each source bucket, so a classification mistake shows up as a count in the
/// wrong place rather than as a plausible-looking total.
fn buildOneOfEach(dl: *DrawList, arena: std.mem.Allocator) !void {
    const col = Color.rgba(0xFF, 0x20, 0x40, 0xFF);
    const r: Rect = .{ .x = 2, .y = 2, .w = 20, .h = 12 };
    try dl.rectFilled(r, col); // sharp_fill
    try dl.rectFilledEx(r, col, .{ .radius = 4 }); // rounded_fill
    try dl.rectOutline(r, col, 1); // sharp_outline
    try dl.rectOutlineEx(r, col, 1, .{ .radius = 4 }); // rounded_outline
    try dl.circleFilled(.{ .x = 30, .y = 30 }, 6, col, .{}); // circle_filled
    try dl.circleOutline(.{ .x = 30, .y = 30 }, 6, col, 1, .{}); // circle_outline
    try dl.line(.{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 }, col, 1); // line
    try dl.text(.{ .x = 1, .y = 1 }, "hi", col); // text
    // The DrawList holds a borrowed slice, so these pixels have to outlive this function.
    const px = try arena.alloc(u32, 4);
    @memset(px, 0xFF00FF00);
    try dl.image(r, px, 2, 2); // image
    {
        var pb = dl.beginPath(arena);
        try pb.moveTo(.{ .x = 4, .y = 4 });
        try pb.lineTo(.{ .x = 16, .y = 4 });
        try pb.lineTo(.{ .x = 16, .y = 16 });
        try pb.finish(.{ .color = col }); // path_fill
    }
    {
        var pb = dl.beginPath(arena);
        try pb.moveTo(.{ .x = 4, .y = 20 });
        try pb.lineTo(.{ .x = 16, .y = 20 });
        try pb.stroke(.{ .color = col, .width = 2 }); // path_stroke
    }
    try dl.shadow(r, col, .{ .radius = 4, .blur = 3 }); // shadow
}

test "renderProfiled: every source bucket is charged exactly once" {
    const gpa = std.testing.allocator;
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(64, 64);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try buildOneOfEach(&dl, arena_state.allocator());

    var pixels = [_]u32{0} ** (64 * 64);
    var profile: RenderProfile = .{};
    test_clock_now = 0;
    test_clock_step = 1;
    renderProfiled(testTarget(&pixels, 64, 64), &dl, font_mod.default_font, 1.0, testClock, &profile);

    inline for (@typeInfo(RenderBucket).@"enum".fields) |f| {
        const bucket: RenderBucket = @enumFromInt(f.value);
        try std.testing.expectEqual(@as(u64, 1), profile.counts[@intFromEnum(bucket)]);
    }
    try std.testing.expectEqual(@as(u64, RenderBucket.count), profile.commands);
}

test "renderProfiled: a clock that advances produces non-zero durations" {
    const gpa = std.testing.allocator;
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(64, 64);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try buildOneOfEach(&dl, arena_state.allocator());

    var pixels = [_]u32{0} ** (64 * 64);
    var profile: RenderProfile = .{};
    test_clock_now = 0;
    test_clock_step = 1; // each read advances by 1, so each command spans exactly 1
    renderProfiled(testTarget(&pixels, 64, 64), &dl, font_mod.default_font, 1.0, testClock, &profile);

    // The instrument reporting zero everywhere is the failure this guards against: it looks
    // exactly like a renderer that costs nothing.
    for (profile.seconds) |v| try std.testing.expect(v > 0);
    try std.testing.expectEqual(@as(f64, RenderBucket.count), profile.total());
}

test "renderProfiled: adding a command moves only its own bucket" {
    const gpa = std.testing.allocator;
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(64, 64);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try buildOneOfEach(&dl, arena_state.allocator());

    var pixels = [_]u32{0} ** (64 * 64);
    var before: RenderProfile = .{};
    test_clock_now = 0;
    test_clock_step = 1;
    renderProfiled(testTarget(&pixels, 64, 64), &dl, font_mod.default_font, 1.0, testClock, &before);

    try dl.line(.{ .x = 1, .y = 1 }, .{ .x = 9, .y = 9 }, Color.rgba(0, 0xFF, 0, 0xFF), 1);
    var after: RenderProfile = .{};
    test_clock_now = 0;
    renderProfiled(testTarget(&pixels, 64, 64), &dl, font_mod.default_font, 1.0, testClock, &after);

    inline for (@typeInfo(RenderBucket).@"enum".fields) |f| {
        const i = f.value;
        const expected = before.counts[i] + @as(u64, if (@as(RenderBucket, @enumFromInt(i)) == .line) 1 else 0);
        try std.testing.expectEqual(expected, after.counts[i]);
    }
}

test "renderProfiled: an empty clip is still dispatched and charged" {
    const gpa = std.testing.allocator;
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(64, 64);
    try dl.pushClip(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
    try dl.rectFilled(.{ .x = 2, .y = 2, .w = 10, .h = 10 }, Color.rgba(0xFF, 0, 0, 0xFF));
    dl.popClip();

    var pixels = [_]u32{0} ** (64 * 64);
    var profile: RenderProfile = .{};
    test_clock_now = 0;
    test_clock_step = 1;
    renderProfiled(testTarget(&pixels, 64, 64), &dl, font_mod.default_font, 1.0, testClock, &profile);

    try std.testing.expectEqual(@as(u64, 1), profile.commands);
    try std.testing.expectEqual(@as(u64, 1), profile.empty_clip);
    try std.testing.expectEqual(@as(u64, 1), profile.counts[@intFromEnum(RenderBucket.sharp_fill)]);
}

test "renderProfiled: attributes are counted across buckets, not as buckets" {
    const gpa = std.testing.allocator;
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(64, 64);
    const r: Rect = .{ .x = 2, .y = 2, .w = 20, .h = 12 };
    const paint: Paint = .{ .linear = .{
        .start = .{ .x = 2, .y = 2 },
        .end = .{ .x = 22, .y = 2 },
        .start_color = Color.rgba(0xFF, 0, 0, 0xFF),
        .end_color = Color.rgba(0, 0, 0xFF, 0xFF),
    } };
    try dl.rectFilledPaint(r, paint);

    var pixels = [_]u32{0} ** (64 * 64);
    var profile: RenderProfile = .{};
    test_clock_now = 0;
    test_clock_step = 1;
    renderProfiled(testTarget(&pixels, 64, 64), &dl, font_mod.default_font, 1.0, testClock, &profile);

    try std.testing.expectEqual(@as(u64, 1), profile.gradient);
    try std.testing.expectEqual(@as(u64, 1), profile.counts[@intFromEnum(RenderBucket.sharp_fill)]);
}

test "renderProfiled: the scaled path is instrumented too" {
    const gpa = std.testing.allocator;
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(64, 64);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try buildOneOfEach(&dl, arena_state.allocator());

    // `render` has a separate loop for scale 1.0, so a profiler wired into only that one
    // passes every scale-1 test while measuring nothing at any other scale.
    var pixels = [_]u32{0} ** (256 * 256);
    for ([_]f32{ 0.5, 2.0 }) |scale| {
        var profile: RenderProfile = .{};
        test_clock_now = 0;
        test_clock_step = 1;
        renderProfiled(testTarget(&pixels, 256, 256), &dl, font_mod.default_font, scale, testClock, &profile);
        try std.testing.expectEqual(@as(u64, RenderBucket.count), profile.commands);
        inline for (@typeInfo(RenderBucket).@"enum".fields) |f| {
            try std.testing.expectEqual(@as(u64, 1), profile.counts[f.value]);
        }
        for (profile.seconds) |v| try std.testing.expect(v > 0);
    }
}

test "renderProfiled: attribute counters track the commands that carry them" {
    const gpa = std.testing.allocator;
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(64, 64);
    const col = Color.rgba(0xFF, 0, 0, 0xFF);
    const r: Rect = .{ .x = 2, .y = 2, .w = 20, .h = 12 };
    try dl.rectFilledEx(r, col, .{ .radius = 4, .aa = true });
    try dl.rectFilledEx(r, col, .{ .radius = 4, .aa = false });
    try dl.textEx(.{ .x = 1, .y = 1 }, "a", col, font_mod.default_font); // font override
    try dl.text(.{ .x = 1, .y = 20 }, "b", col); // no override

    var pixels = [_]u32{0} ** (64 * 64);
    var profile: RenderProfile = .{};
    test_clock_now = 0;
    test_clock_step = 1;
    renderProfiled(testTarget(&pixels, 64, 64), &dl, font_mod.default_font, 1.0, testClock, &profile);

    try std.testing.expectEqual(@as(u64, 1), profile.antialiased);
    try std.testing.expectEqual(@as(u64, 1), profile.font_override);
    try std.testing.expectEqual(@as(u64, 2), profile.counts[@intFromEnum(RenderBucket.text)]);
}

test "renderProfiled: an empty clip is counted at the scale the renderer tests" {
    const gpa = std.testing.allocator;
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(64, 64);
    // One logical pixel wide: not empty as written, empty once scaled down.
    try dl.pushClip(.{ .x = 0, .y = 0, .w = 1, .h = 1 });
    try dl.rectFilled(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, Color.rgba(0xFF, 0, 0, 0xFF));
    dl.popClip();

    var pixels = [_]u32{0} ** (64 * 64);

    var at_one: RenderProfile = .{};
    test_clock_now = 0;
    test_clock_step = 1;
    renderProfiled(testTarget(&pixels, 64, 64), &dl, font_mod.default_font, 1.0, testClock, &at_one);
    try std.testing.expectEqual(@as(u64, 0), at_one.empty_clip);

    var shrunk: RenderProfile = .{};
    test_clock_now = 0;
    renderProfiled(testTarget(&pixels, 64, 64), &dl, font_mod.default_font, 0.25, testClock, &shrunk);
    try std.testing.expectEqual(@as(u64, 1), shrunk.empty_clip);
}

test "renderProfiled draws exactly what render draws" {
    const gpa = std.testing.allocator;
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(64, 64);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try buildOneOfEach(&dl, arena_state.allocator());

    // Measuring must not change the picture. Without this, an instrumented path could drift
    // from the ordinary one and every timing above would describe a renderer nobody ships.
    for ([_]f32{ 1.0, 0.5, 2.0 }) |scale| {
        var plain = [_]u32{0} ** (256 * 256);
        var profiled = [_]u32{0} ** (256 * 256);
        render(testTarget(&plain, 256, 256), &dl, font_mod.default_font, scale);
        var profile: RenderProfile = .{};
        test_clock_now = 0;
        test_clock_step = 1;
        renderProfiled(testTarget(&profiled, 256, 256), &dl, font_mod.default_font, scale, testClock, &profile);
        try std.testing.expectEqualSlices(u32, &plain, &profiled);
    }
}

test "renderProfiled: a command counted as clipped away really does not draw" {
    const gpa = std.testing.allocator;
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(64, 64);
    try dl.pushClip(.{ .x = 0, .y = 0, .w = 1, .h = 1 });
    try dl.rectFilled(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, Color.rgba(0xFF, 0, 0, 0xFF));
    dl.popClip();

    // `empty_clip` is a claim about the renderer's behaviour, so check the framebuffer and not
    // only the counter: agreeing with itself is not evidence.
    var shrunk = [_]u32{0} ** (64 * 64);
    var profile_shrunk: RenderProfile = .{};
    test_clock_now = 0;
    test_clock_step = 1;
    renderProfiled(testTarget(&shrunk, 64, 64), &dl, font_mod.default_font, 0.25, testClock, &profile_shrunk);
    try std.testing.expectEqual(@as(u64, 1), profile_shrunk.empty_clip);
    for (shrunk) |px| try std.testing.expectEqual(@as(u32, 0), px);

    var drawn = [_]u32{0} ** (64 * 64);
    var profile_drawn: RenderProfile = .{};
    test_clock_now = 0;
    renderProfiled(testTarget(&drawn, 64, 64), &dl, font_mod.default_font, 1.0, testClock, &profile_drawn);
    try std.testing.expectEqual(@as(u64, 0), profile_drawn.empty_clip);
    var touched: usize = 0;
    for (drawn) |px| {
        if (px != 0) touched += 1;
    }
    try std.testing.expect(touched > 0);
}
