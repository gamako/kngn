//! apps/noodle: pure geometry / hit-test logic for the patch canvas.
//!
//! Pure Zig with no platform / gui / modular imports. Camera transforms, node/port geometry, hit-testing,
//! and viewport-containment checks (automatic off-screen detection) are provided here, unit-testable without display/audio (test-noodle).
//! Drawing/input (main.zig) only layers window, DrawList, and events on top of this logic.

const std = @import("std");

pub const Handle = u16;

pub const Vec2f = struct {
    x: f32,
    y: f32,
    pub fn add(a: Vec2f, b: Vec2f) Vec2f {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Vec2f, b: Vec2f) Vec2f {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(a: Vec2f, s: f32) Vec2f {
        return .{ .x = a.x * s, .y = a.y * s };
    }
};

// --- Layout constants (world units) ---
pub const NODE_W: f32 = 120;
pub const TITLE_H: f32 = 22;
pub const PORT_SPACING: f32 = 20;
pub const BODY_PAD: f32 = 8; // Margin below the port band
pub const WORLD_PORT_R: f32 = 6;
pub const PORT_R_MIN: f32 = 3;
pub const PORT_R_MAX: f32 = 10;
pub const ZOOM_MIN: f32 = 0.25;
pub const ZOOM_MAX: f32 = 4.0;
pub const CABLE_HIT_SLOP: f32 = 6; // Cable hit-test threshold, in world units

// Inspector slider rows match the GUI widget's [label] [track] [value] structure.
// value_w is the fixed reserved width for the max value string (f32 decimal display); track_min is the lower
// bound that keeps an operable track area even for short labels. At the usual inspector content width (260px),
// both value_w and track_min stay at their fixed values.
// The outer frame (right/bottom slot) is owned by PanelHost.
pub const INSPECTOR_PARAM_GAP: i32 = 6;
pub const INSPECTOR_PARAM_VALUE_W: i32 = 64;
pub const INSPECTOR_PARAM_TRACK_MIN: i32 = 48;

pub const ParamRowLayout = struct {
    label_w: i32,
    track_w: i32,
    value_w: i32,

    pub fn total(self: ParamRowLayout) i32 {
        return self.label_w + self.track_w + self.value_w + 2 * INSPECTOR_PARAM_GAP;
    }
};

/// Returns the pure horizontal layout of a slider row that fits within the inspector content width.
///
/// label_w is the measured label width. For long labels, value_w + track_min + gap are reserved first,
/// and the label is truncated; the remainder goes to the track. In extremely narrow viewports, value/track
/// are shrunk, but at the usual panel width value_w=64 and track_min=48 are kept.
pub fn inspectorParamRowLayout(avail: i32, label_w: i32) ParamRowLayout {
    const width = @max(avail, 0);
    const gap_w = 2 * INSPECTOR_PARAM_GAP;
    const value_w = @min(INSPECTOR_PARAM_VALUE_W, @max(0, width - gap_w - INSPECTOR_PARAM_TRACK_MIN));
    const track_min = @min(INSPECTOR_PARAM_TRACK_MIN, @max(0, width - gap_w - value_w));
    const label_max = @max(0, width - gap_w - value_w - track_min);
    const fitted_label = @min(@max(label_w, 0), label_max);
    const track_w = @max(track_min, width - gap_w - value_w - fitted_label);
    return .{ .label_w = fitted_label, .track_w = track_w, .value_w = value_w };
}

/// Node geometry passed in by the drawing side. pos is the world-space top-left.
/// grid_rows>0 marks a box that draws a step grid in its body (a collapsed macro box, or a selected standalone step_seq):
/// nodeSize reserves height for the grid rows in addition to the port-count-derived height (the hit-test rect stays consistent with the same height).
/// 0 = no grid. 1 = drum standalone on row. 4 = bass standalone on/accent/slide/pitch. Macro boxes derive this from group metadata.
pub const NodeGeom = struct {
    handle: Handle,
    pos: Vec2f,
    n_in: u8,
    n_out: u8,
    grid_rows: u8 = 0,
};

/// A connection from output port src_out to input port dst_in (unique by dst since each input has a single connection).
pub const Edge = struct {
    src_handle: Handle,
    src_out: u8,
    dst_handle: Handle,
    dst_in: u8,
};

pub const PortRef = struct {
    handle: Handle,
    is_input: bool,
    index: u8,
};

/// A cable's stable ID (unique by input port since each input has a single connection). Used for select/delete (the per-frame edge index
/// is not used for this because add/remove/publish can make it refer to a different cable).
pub const CableRef = struct {
    dst_handle: Handle,
    dst_in: u8,
};

pub const ScreenRect = struct { x: f32, y: f32, w: f32, h: f32 };

/// An axis-aligned rectangle in world coordinates (w/h are assumed non-negative; normalizeWorldRect guarantees this).
pub const WorldRect = struct { x: f32, y: f32, w: f32, h: f32 };

/// A module palette button (screen coordinates, independent of pan/zoom).
pub const PaletteButton = struct {
    kind_index: u8,
    rect: ScreenRect,
};

/// Builds a normalized world rect from two points (w,h >= 0 regardless of drag direction).
pub fn normalizeWorldRect(a: Vec2f, b: Vec2f) WorldRect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// The world-space bbox of a display node (pos + nodeSize).
pub fn nodeWorldBBox(g: NodeGeom) WorldRect {
    const sz = nodeSize(g);
    return .{ .x = g.pos.x, .y = g.pos.y, .w = sz.x, .h = sz.y };
}

/// An intersection with positive area (full containment and partial overlap are a hit; boundary-only touch or zero-size is a miss).
pub fn rectsIntersectPositive(a: WorldRect, b: WorldRect) bool {
    if (a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0) return false;
    const ix = @min(a.x + a.w, b.x + b.w) - @max(a.x, b.x);
    const iy = @min(a.y + a.h, b.y + b.h) - @max(a.y, b.y);
    return ix > 0 and iy > 0;
}

/// Determines a cable's src (output) / dst (input) from two ports. Valid only when one is an output and the other is an input.
/// Same-direction pairs (out-out / in-in, including the same PortRef) yield null. An out->in pair on the same node (a different port, i.e. a self-loop) is allowed
/// (the engine treats it as a delay edge). Kind matching is validated beforehand by the caller (dyn.outKindOf/inKindOf).
pub fn resolveConnection(a: PortRef, b: PortRef) ?struct { src: PortRef, dst: PortRef } {
    if (a.is_input == b.is_input) return null; // Same direction (the same PortRef is also rejected here)
    const src = if (!a.is_input) a else b;
    const dst = if (a.is_input) a else b;
    return .{ .src = src, .dst = dst };
}

fn pointInScreenRect(mx: f32, my: f32, r: ScreenRect) bool {
    return mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h;
}

/// Which palette button the mouse is over, in screen coordinates (checked before the world hit-test).
pub fn hitTestPalette(mouse: Vec2f, buttons: []const PaletteButton) ?u8 {
    for (buttons) |btn| {
        if (pointInScreenRect(mouse.x, mouse.y, btn.rect)) return btn.kind_index;
    }
    return null;
}

pub const OffscreenCounts = struct {
    node: u32 = 0,
    port: u32 = 0,
    cable: u32 = 0,
};

// ============================================================================
// Node/port geometry (world coordinates)
// ============================================================================

/// The number of port rows (the larger of input/output count; at least 1).
fn rowCount(g: NodeGeom) f32 {
    const rows = @max(g.n_in, g.n_out);
    return @floatFromInt(@max(rows, 1));
}

/// A node's world-space size (fixed width; height depends on port count, tall enough to avoid clipping).
/// When grid_rows>0 (a macro box or a selected standalone step_seq), the larger of the port height and the grid height is used.
/// A node with n_out>0 always adds the mini-scope/parameter-value band (MINI_H+MINI_GAP) to its height
/// (the height does not change with whether a tap is active, so cable tracking stays stable during drag; the band is empty when untapped).
pub fn nodeSize(g: NodeGeom) Vec2f {
    const port_h = TITLE_H + PORT_SPACING * rowCount(g) + BODY_PAD;
    const base_h = if (g.grid_rows == 0) port_h else @max(port_h, TITLE_H + gridBlockHeight(g.grid_rows) + BODY_PAD);
    const band: f32 = if (g.n_out > 0) MINI_H + MINI_GAP else 0;
    return .{ .x = NODE_W, .y = base_h + band };
}

/// The world-space center of input port i (on the left edge).
pub fn inPortPos(g: NodeGeom, i: u8) Vec2f {
    const fi: f32 = @floatFromInt(i);
    return .{ .x = g.pos.x, .y = g.pos.y + TITLE_H + PORT_SPACING * (fi + 0.5) };
}

/// The world-space center of output port j (on the right edge).
pub fn outPortPos(g: NodeGeom, j: u8) Vec2f {
    const fj: f32 = @floatFromInt(j);
    return .{ .x = g.pos.x + NODE_W, .y = g.pos.y + TITLE_H + PORT_SPACING * (fj + 0.5) };
}

fn portPos(g: NodeGeom, is_input: bool, index: u8) Vec2f {
    return if (is_input) inPortPos(g, index) else outPortPos(g, index);
}

fn pointInRect(p: Vec2f, top_left: Vec2f, size: Vec2f) bool {
    return p.x >= top_left.x and p.x <= top_left.x + size.x and
        p.y >= top_left.y and p.y <= top_left.y + size.y;
}

fn findNode(nodes: []const NodeGeom, h: Handle) ?NodeGeom {
    for (nodes) |n| {
        if (n.handle == h) return n;
    }
    return null;
}

// ============================================================================
// Camera (world <-> screen transform)
// ============================================================================
pub const Camera = struct {
    pan: Vec2f = .{ .x = 0, .y = 0 },
    zoom: f32 = 1.0,

    pub fn worldToScreen(c: Camera, w: Vec2f) Vec2f {
        return .{ .x = w.x * c.zoom + c.pan.x, .y = w.y * c.zoom + c.pan.y };
    }
    pub fn screenToWorld(c: Camera, s: Vec2f) Vec2f {
        return .{ .x = (s.x - c.pan.x) / c.zoom, .y = (s.y - c.pan.y) / c.zoom };
    }

    /// Zooms while keeping the world point under the cursor fixed (zoom is clamped to [ZOOM_MIN,ZOOM_MAX]).
    pub fn zoomAt(c: *Camera, cursor_screen: Vec2f, factor: f32) void {
        const new_zoom = std.math.clamp(c.zoom * factor, ZOOM_MIN, ZOOM_MAX);
        const eff = new_zoom / c.zoom; // Effective scale after clamping
        c.pan = .{
            .x = cursor_screen.x - (cursor_screen.x - c.pan.x) * eff,
            .y = cursor_screen.y - (cursor_screen.y - c.pan.y) * eff,
        };
        c.zoom = new_zoom;
    }

    /// A port's screen-space draw radius, clamped so it neither vanishes at zoom 0.25 nor bloats at zoom 4.
    pub fn portScreenRadius(c: Camera) f32 {
        return std.math.clamp(WORLD_PORT_R * c.zoom, PORT_R_MIN, PORT_R_MAX);
    }
};

// ============================================================================
// Hit-testing (evaluated in world coordinates; the caller applies screenToWorld before calling)
// ============================================================================

/// The frontmost node containing a world point (reverse draw order, i.e. last wins).
pub fn hitTestNode(world_pt: Vec2f, nodes: []const NodeGeom) ?Handle {
    var i: usize = nodes.len;
    while (i > 0) {
        i -= 1;
        const g = nodes[i];
        if (pointInRect(world_pt, g.pos, nodeSize(g))) return g.handle;
    }
    return null;
}

/// The port nearest a world point (hit radius = WORLD_PORT_R; frontmost wins).
pub fn hitTestPort(world_pt: Vec2f, nodes: []const NodeGeom) ?PortRef {
    var i: usize = nodes.len;
    while (i > 0) {
        i -= 1;
        const g = nodes[i];
        var k: u8 = 0;
        while (k < g.n_in) : (k += 1) {
            if (dist(world_pt, inPortPos(g, k)) <= WORLD_PORT_R) return .{ .handle = g.handle, .is_input = true, .index = k };
        }
        k = 0;
        while (k < g.n_out) : (k += 1) {
            if (dist(world_pt, outPortPos(g, k)) <= WORLD_PORT_R) return .{ .handle = g.handle, .is_input = false, .index = k };
        }
    }
    return null;
}

// ----------------------------------------------------------------------------
// Collapse toggle [+/-]: a small rect at the right end of the title row. This assumes group.zig's collapsed box / expanded-frame header is
// represented as a NodeGeom shape, and only places positioning/hit-testing here (since group.zig is modular-independent,
// the meaning of a synthetic handle is main.zig's responsibility; this file is pure geometry).
// ----------------------------------------------------------------------------
pub const TOGGLE_SIZE: f32 = 14;
pub const TOGGLE_MARGIN: f32 = 4;

/// The world-space top-left position of the collapse toggle within the title row (right-aligned to the node, based on the fixed NODE_W).
pub fn togglePos(g: NodeGeom) Vec2f {
    return .{ .x = g.pos.x + NODE_W - TOGGLE_SIZE - TOGGLE_MARGIN, .y = g.pos.y + (TITLE_H - TOGGLE_SIZE) / 2 };
}

fn pointInToggle(world_pt: Vec2f, g: NodeGeom) bool {
    return pointInRect(world_pt, togglePos(g), .{ .x = TOGGLE_SIZE, .y = TOGGLE_SIZE });
}

/// The node whose toggle is near a world point (frontmost wins).
pub fn hitTestToggle(world_pt: Vec2f, nodes: []const NodeGeom) ?Handle {
    var i: usize = nodes.len;
    while (i > 0) {
        i -= 1;
        const g = nodes[i];
        if (pointInToggle(world_pt, g)) return g.handle;
    }
    return null;
}

// ----------------------------------------------------------------------------
// Step-grid layout constants (shared by macro boxes and standalone step_seq).
// Cell rects and hit-testing are centrally managed by libs/gui.stepgrid; main.zig acts as the adapter
// before/after the camera transform.
// ----------------------------------------------------------------------------
pub const GRID_STEPS: u8 = 16;
pub const GRID_SIDE_PAD: f32 = 10; // Left/right margin (avoids the left/right port dots)
pub const GRID_TOP_PAD: f32 = 4; // Gap from below the title to the start of the grid
pub const GRID_CELL_H: f32 = 8; // Cell height
pub const GRID_ROW_GAP: f32 = 2; // Row spacing
/// The evolve/lock toggles in a macro box's title band (do not collide with the step grid).
pub const MACRO_MUT_TOGGLE_W: f32 = 12;
pub const MACRO_MUT_TOGGLE_H: f32 = 10;
pub const MACRO_MUT_TOGGLE_GAP: f32 = 4;

pub const MacroToggleRect = struct { x: f32, y: f32, w: f32, h: f32 };

/// Box-local: the evolve toggle rect (at the left end of the title band; does not collide with the collapse [+/-]).
pub fn macroEvolveToggleRect() MacroToggleRect {
    return .{
        .x = GRID_SIDE_PAD,
        .y = (TITLE_H - MACRO_MUT_TOGGLE_H) * 0.5,
        .w = MACRO_MUT_TOGGLE_W,
        .h = MACRO_MUT_TOGGLE_H,
    };
}

/// Box-local: the lock toggle for the given lane (laid out to the right of evolve).
pub fn macroLockToggleRect(lane: u8) MacroToggleRect {
    const e = macroEvolveToggleRect();
    const x = e.x + e.w + MACRO_MUT_TOGGLE_GAP + @as(f32, @floatFromInt(lane)) * (MACRO_MUT_TOGGLE_W + MACRO_MUT_TOGGLE_GAP);
    return .{ .x = x, .y = e.y, .w = MACRO_MUT_TOGGLE_W, .h = MACRO_MUT_TOGGLE_H };
}

/// A check guaranteeing the toggle band sits above the step grid origin (no collision).
pub fn macroToggleAboveGrid(r: MacroToggleRect) bool {
    return r.y + r.h <= TITLE_H + GRID_TOP_PAD - 0.5;
}

/// The width the evolve + lock (n lanes) toggle band occupies from the left end of the title band (box-local).
/// The title text's draw x is offset to the right by this amount to avoid visually overlapping the toggles
/// (without this, the toggles and title text land in the same x band and
/// become unreadable; when n=0 this returns 0 and the text position is unchanged).
pub fn macroToggleReservedWidth(n: u8) f32 {
    if (n == 0) return 0;
    const e = macroEvolveToggleRect();
    return e.x + e.w + MACRO_MUT_TOGGLE_GAP + @as(f32, @floatFromInt(n)) * (MACRO_MUT_TOGGLE_W + MACRO_MUT_TOGGLE_GAP);
}

/// Box-local / screen grid geometry computed before handing off to stepgrid. Even on the canvas side, which does not import gui,
/// this unifies the adapter input so drawing and hit-testing use the same constants.
pub const GridGeometry = struct {
    origin_x: f32,
    origin_y: f32,
    cell_w: f32,
    cell_h: f32,
    step_pitch: f32,
    row_pitch: f32,
};

/// The horizontal pitch of one step (cell width plus gap). 16 steps fit within the box's inner width.
pub fn gridStepWidth() f32 {
    return (NODE_W - 2 * GRID_SIDE_PAD) / @as(f32, @floatFromInt(GRID_STEPS));
}

/// The height from the bottom of the title to the bottom of the grid, for the given row count. Used by nodeSize to extend the box height.
pub fn gridBlockHeight(rows: u8) f32 {
    const fr: f32 = @floatFromInt(rows);
    return GRID_TOP_PAD + fr * (GRID_CELL_H + GRID_ROW_GAP);
}

/// Grid geometry shared by nodes and macro boxes: camera-transformed origin / cell size / pitch.
/// For a box-local call, pass box_pos = (0, 0) and zoom = 1.
pub fn gridGeometry(cam: Camera, box_pos: Vec2f) GridGeometry {
    const top_left = cam.worldToScreen(box_pos);
    const step_pitch = gridStepWidth() * cam.zoom;
    return .{
        .origin_x = top_left.x + GRID_SIDE_PAD * cam.zoom,
        .origin_y = top_left.y + (TITLE_H + GRID_TOP_PAD) * cam.zoom,
        .cell_w = step_pitch - 1.5 * cam.zoom,
        .cell_h = GRID_CELL_H * cam.zoom,
        .step_pitch = step_pitch,
        .row_pitch = (GRID_CELL_H + GRID_ROW_GAP) * cam.zoom,
    };
}

/// The cable near a world point (point-to-segment distance <= CABLE_HIT_SLOP). Returns an edge index.
pub fn hitTestCable(world_pt: Vec2f, nodes: []const NodeGeom, edges: []const Edge) ?usize {
    var idx: usize = edges.len;
    while (idx > 0) {
        idx -= 1;
        const e = edges[idx];
        const sg = findNode(nodes, e.src_handle) orelse continue;
        const dg = findNode(nodes, e.dst_handle) orelse continue;
        const a = outPortPos(sg, e.src_out);
        const b = inPortPos(dg, e.dst_in);
        if (distPointSegment(world_pt, a, b) <= CABLE_HIT_SLOP) return idx;
    }
    return null;
}

fn dist(a: Vec2f, b: Vec2f) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

/// The distance from point p to segment ab.
fn distPointSegment(p: Vec2f, a: Vec2f, b: Vec2f) f32 {
    const abx = b.x - a.x;
    const aby = b.y - a.y;
    const len2 = abx * abx + aby * aby;
    if (len2 <= 1e-9) return dist(p, a);
    var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2;
    t = std.math.clamp(t, 0.0, 1.0);
    const proj = Vec2f{ .x = a.x + abx * t, .y = a.y + aby * t };
    return dist(p, proj);
}

// ============================================================================
// Mini oscilloscope: geometry for a small recent-waveform window per output port, plus tap-target selection (pure logic).
// One window is shown per node (out0 is the representative), placed at a fixed screen size inside the node's rect near its bottom edge, and it tracks the node position.
// Independent of modular / dyn (resolving the global port id is main.zig's responsibility).
// ============================================================================
pub const MINI_W: f32 = 64; // World units (changed from fixed screen px to world units, to align with the node's
// other geometry (NODE_W etc.) under the same scale assumption, so it can be folded into nodeSize() as a band)
pub const MINI_H: f32 = 28; // World units
pub const MINI_GAP: f32 = 4; // World units (inner margin between the node's bottom edge and the top of the scope band)
pub const MINI_ZOOM_MIN: f32 = 0.5; // Hidden below this zoom level (an unreadable window, so no RT tap is allocated for it)
/// The upper bound of selectTapPortsStable's temporary candidate buffer. It comfortably exceeds
/// the caller's TAP_SLOTS(16); canvas.zig does not import TAP_SLOTS directly since it is modular/dyn-independent.
const MAX_TAP_CANDIDATES: usize = 32;

/// The mini-scope rect placed inside the node, near its bottom edge (screen coordinates). It is drawn inside the node frame rather than outside it (a band
/// of MINI_H+MINI_GAP above the bottom edge). `node_tl_screen`/`node_size_screen` are already
/// zoom-applied by the caller (screen coordinates), while `MINI_W`/`MINI_H`/`MINI_GAP` are world-unit constants, so `zoom` is
/// multiplied in here (the contract is that this multiplication happens only inside this function, to avoid double- or un-scaling).
pub fn miniScopeRect(node_tl_screen: Vec2f, node_size_screen: Vec2f, zoom: f32) ScreenRect {
    return .{
        .x = node_tl_screen.x,
        .y = node_tl_screen.y + node_size_screen.y - (MINI_H + MINI_GAP) * zoom,
        .w = MINI_W * zoom,
        .h = MINI_H * zoom,
    };
}

/// The mini-scope's display start index (rising zero-crossing trigger). Given `samples` ordered oldest->newest, when showing the trailing `disp`
/// points, the display window is aligned to the most recent rising zero-crossing so a periodic waveform appears still. If there is no crossing
/// (e.g. a gate/unipolar CV signal that never crosses zero), it naturally falls back to the newest window (unlocked, scrolling display).
/// The returned start always satisfies start+disp<=samples.len, so the caller's slice is safe.
pub fn findTriggerStart(samples: []const f32, disp: usize) usize {
    const n = samples.len;
    if (disp >= n or disp < 2) return if (n > disp) n - disp else 0;
    const newest = n - disp; // Start when unlocked (the newest disp points)
    var t = newest;
    while (t > 0) : (t -= 1) {
        if (samples[t - 1] < 0.0 and samples[t] >= 0.0) return t; // The most recent rising crossing at or before newest
    }
    return newest;
}

/// Whether a node is a tap candidate: it has an output port and its rect intersects the viewport (since the mini-scope is now drawn inside the node,
/// this checks only whether the node itself intersects the viewport, not full containment. A node that is only
/// partially visible near the bottom edge is still included. vh is the canvas's usable height).
fn isTapCandidate(cam: Camera, vw: f32, vh: f32, g: NodeGeom) bool {
    if (g.n_out == 0) return false;
    if (cam.zoom < MINI_ZOOM_MIN) return false;
    const tl = cam.worldToScreen(g.pos);
    const sz = nodeSize(g).scale(cam.zoom);
    return tl.x < vw and tl.x + sz.x > 0 and tl.y < vh and tl.y + sz.y > 0;
}

fn containsHandle(list: []const Handle, h: Handle) bool {
    for (list) |x| {
        if (x == h) return true;
    }
    return false;
}

/// Selects up to out.len node handles for mini-scope display (i.e. tap targets) into `out`, in priority order.
/// At zoom<MINI_ZOOM_MIN, zero taps are selected. Priority order: selected > hover > the nodes list order.
/// The returned handles are display-node handles (a collapsed box's synthetic handle is allowed; resolving the global port id is the caller's job).
pub fn selectTapPorts(
    cam: Camera,
    vw: f32,
    vh: f32,
    nodes: []const NodeGeom,
    selected: ?Handle,
    hover: ?Handle,
    out: []Handle,
) usize {
    if (cam.zoom < MINI_ZOOM_MIN or out.len == 0) return 0;
    var n: usize = 0;
    if (selected) |sh| {
        if (findNode(nodes, sh)) |g| {
            if (isTapCandidate(cam, vw, vh, g) and n < out.len) {
                out[n] = sh;
                n += 1;
            }
        }
    }
    if (hover) |hh| {
        if (findNode(nodes, hh)) |g| {
            if (isTapCandidate(cam, vw, vh, g) and !containsHandle(out[0..n], hh) and n < out.len) {
                out[n] = hh;
                n += 1;
            }
        }
    }
    for (nodes) |g| {
        if (n >= out.len) break;
        if (isTapCandidate(cam, vw, vh, g) and !containsHandle(out[0..n], g.handle)) {
            out[n] = g.handle;
            n += 1;
        }
    }
    return n;
}

fn keptElsewhere(slots: []const ?Handle, h: Handle) bool {
    for (slots) |m| {
        if (m) |x| {
            if (x == h) return true;
        }
    }
    return false;
}

/// Stable tap-target selection. Of `prev` (the previous display handle for each slot; empty slots are null),
/// entries that still satisfy `isTapCandidate` this frame are kept **in the same slot number**, so unrelated hover/selected
/// changes do not cause a collateral reset.
///
/// **Only selected/hover entries may be evicted.** Giving eviction rights to ordinary candidates too (those chosen
/// only by scan order, with lower priority) would, once candidates exceed the cap, cause frame A/B to be
/// evicted by ordinary candidates C/D one frame, then C/D evicted by A/B the next, and so on: a perpetual
/// rotation across frames that would republish the tap config and reset the RT ring on every frame.
/// Empty slots get new candidates assigned in priority order selected > hover > nodes scan order, but **when there is no empty slot,
/// only selected/hover candidates may reclaim an existing retained slot** (an ordinary candidate that is
/// neither selected nor hover is dropped for that frame if no slot is free; stability comes first).
/// `prev`/`out` have the same length (matching the caller's TAP_SLOTS). `out` may be the same buffer as `prev` or a different one.
pub fn selectTapPortsStable(
    cam: Camera,
    vw: f32,
    vh: f32,
    nodes: []const NodeGeom,
    selected: ?Handle,
    hover: ?Handle,
    prev: []const ?Handle,
    out: []?Handle,
) void {
    std.debug.assert(out.len == prev.len);
    const cap = out.len;
    if (cap == 0) return;
    if (cam.zoom < MINI_ZOOM_MIN) {
        for (out) |*o| o.* = null;
        return;
    }

    // 1. Determine which existing slots are retained (keeping their slot numbers).
    for (prev, 0..) |maybe_h, idx| {
        out[idx] = null;
        if (maybe_h) |h| {
            if (findNode(nodes, h)) |g| {
                if (isTapCandidate(cam, vw, vh, g)) out[idx] = h;
            }
        }
    }

    // 2a. Priority candidates (selected/hover only, excluding already-retained handles). At most 2 entries.
    std.debug.assert(cap <= MAX_TAP_CANDIDATES);
    var priority: [2]Handle = undefined;
    var nprio: usize = 0;
    if (selected) |sh| {
        if (findNode(nodes, sh)) |g| {
            if (isTapCandidate(cam, vw, vh, g) and !keptElsewhere(out, sh)) {
                priority[nprio] = sh;
                nprio += 1;
            }
        }
    }
    if (hover) |hh| {
        if (findNode(nodes, hh)) |g| {
            if (isTapCandidate(cam, vw, vh, g) and !keptElsewhere(out, hh) and
                !containsHandle(priority[0..nprio], hh))
            {
                priority[nprio] = hh;
                nprio += 1;
            }
        }
    }

    // 2b. Ordinary candidates (nodes scan order, excluding priority candidates and retained handles; capped).
    var plain: [MAX_TAP_CANDIDATES]Handle = undefined;
    var nplain: usize = 0;
    for (nodes) |g| {
        if (nprio + nplain >= cap) break;
        if (isTapCandidate(cam, vw, vh, g) and !keptElsewhere(out, g.handle) and
            !containsHandle(priority[0..nprio], g.handle) and !containsHandle(plain[0..nplain], g.handle))
        {
            plain[nplain] = g.handle;
            nplain += 1;
        }
    }

    // 3. Fill empty slots (priority candidates first, then ordinary candidates). `locked` is set only on slots
    // newly assigned within this call (slots retained in step 1 are not locked, so they can still be
    // evicted, by a priority candidate only, when full. This is the path taken when a new selected
    // replaces an old hover at capacity 1).
    var locked: [MAX_TAP_CANDIDATES]bool = [_]bool{false} ** MAX_TAP_CANDIDATES;
    var pi: usize = 0; // priority index
    var qi: usize = 0; // plain index
    for (out, 0..) |*o, idx| {
        if (o.* != null) continue; // Retained in step 1 (not locked)
        if (pi < nprio) {
            o.* = priority[pi];
            pi += 1;
        } else if (qi < nplain) {
            o.* = plain[qi];
            qi += 1;
        } else continue;
        locked[idx] = true; // Newly filled. The same slot is not evicted again in a later iteration of this call
    }

    // 4. Eviction when full (**priority candidates only**; unassigned ordinary candidates are dropped when there is no free slot, prioritizing stability).
    while (pi < nprio) {
        var victim: ?usize = null;
        for (out, 0..) |o, idx| {
            if (locked[idx]) continue;
            const h = o orelse continue;
            if (selected != null and h == selected.?) continue;
            if (hover != null and h == hover.?) continue;
            victim = idx;
            break;
        }
        const v = victim orelse break; // No eviction target (e.g. the cap is already filled by selected+hover)
        out[v] = priority[pi];
        locked[v] = true; // The same slot is not chosen as a victim again in a later iteration
        pi += 1;
    }
}

// ============================================================================
// Viewport-containment check (automatic off-screen detection)
// ============================================================================

fn pointInViewport(p: Vec2f, vw: f32, vh: f32) bool {
    return p.x >= 0 and p.x <= vw and p.y >= 0 and p.y <= vh;
}

/// Whether, in screen space, all node rects, port circles, and cable endpoints fit within the viewport [0,vw]x[0,vh].
/// Returns the offscreen count (0 = nothing clipped). Used to check the invariant for initial or controlled representative layouts.
pub fn viewportContains(cam: Camera, vw: f32, vh: f32, nodes: []const NodeGeom, edges: []const Edge) OffscreenCounts {
    var out = OffscreenCounts{};
    const r = cam.portScreenRadius();
    for (nodes) |g| {
        const tl = cam.worldToScreen(g.pos);
        const sz = nodeSize(g).scale(cam.zoom);
        const br = Vec2f{ .x = tl.x + sz.x, .y = tl.y + sz.y };
        if (!pointInViewport(tl, vw, vh) or !pointInViewport(br, vw, vh)) out.node += 1;

        var k: u8 = 0;
        while (k < g.n_in) : (k += 1) {
            if (!portCircleInside(cam.worldToScreen(inPortPos(g, k)), r, vw, vh)) out.port += 1;
        }
        k = 0;
        while (k < g.n_out) : (k += 1) {
            if (!portCircleInside(cam.worldToScreen(outPortPos(g, k)), r, vw, vh)) out.port += 1;
        }
    }
    for (edges) |e| {
        const sg = findNode(nodes, e.src_handle) orelse continue;
        const dg = findNode(nodes, e.dst_handle) orelse continue;
        const a = cam.worldToScreen(outPortPos(sg, e.src_out));
        const b = cam.worldToScreen(inPortPos(dg, e.dst_in));
        if (!pointInViewport(a, vw, vh) or !pointInViewport(b, vw, vh)) out.cable += 1;
    }
    return out;
}

fn portCircleInside(center: Vec2f, r: f32, vw: f32, vh: f32) bool {
    return center.x - r >= 0 and center.x + r <= vw and center.y - r >= 0 and center.y + r <= vh;
}

// ============================================================================
// tests (no display/audio needed; test-noodle)
// ============================================================================
const testing = std.testing;

fn expectApproxVec(a: Vec2f, b: Vec2f) !void {
    try testing.expectApproxEqAbs(a.x, b.x, 1e-3);
    try testing.expectApproxEqAbs(a.y, b.y, 1e-3);
}

test "canvas: worldToScreen/screenToWorld round-trip" {
    const cams = [_]Camera{
        .{ .pan = .{ .x = 0, .y = 0 }, .zoom = 1.0 },
        .{ .pan = .{ .x = 30, .y = -12 }, .zoom = 2.0 },
        .{ .pan = .{ .x = -100, .y = 50 }, .zoom = 0.25 },
    };
    for (cams) |c| {
        const w = Vec2f{ .x = 123.5, .y = -7.25 };
        try expectApproxVec(w, c.screenToWorld(c.worldToScreen(w)));
    }
}

test "canvas: zoomAt keeps cursor world point fixed" {
    var c = Camera{ .pan = .{ .x = 40, .y = 20 }, .zoom = 1.0 };
    const cursor = Vec2f{ .x = 300, .y = 200 };
    const w_before = c.screenToWorld(cursor);
    c.zoomAt(cursor, 1.5);
    const w_after = c.screenToWorld(cursor);
    try expectApproxVec(w_before, w_after);
    // clamp: an upper bound even at extreme zoom-in, a lower bound even at zoom-out
    c.zoomAt(cursor, 100.0);
    try testing.expectApproxEqAbs(ZOOM_MAX, c.zoom, 1e-6);
    c.zoomAt(cursor, 0.0001);
    try testing.expectApproxEqAbs(ZOOM_MIN, c.zoom, 1e-6);
    // The world point under the cursor stays fixed even when clamped
    const w2 = c.screenToWorld(cursor);
    c.zoomAt(cursor, 2.0);
    try expectApproxVec(w2, c.screenToWorld(cursor));
}

test "canvas: hitTestNode inside/outside and topmost on overlap" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 50, .y = 20 }, .n_in = 2, .n_out = 1 }, // Overlaps with 0
    };
    // In the overlap region, the last one (handle 1) is frontmost
    try testing.expectEqual(@as(?Handle, 1), hitTestNode(.{ .x = 60, .y = 30 }, &nodes));
    // Region belonging only to node0
    try testing.expectEqual(@as(?Handle, 0), hitTestNode(.{ .x = 10, .y = 10 }, &nodes));
    // Not inside any node
    try testing.expectEqual(@as(?Handle, null), hitTestNode(.{ .x = 500, .y = 500 }, &nodes));
}

test "canvas: port positions lie on node edges within node rect" {
    const g = NodeGeom{ .handle = 3, .pos = .{ .x = 10, .y = 10 }, .n_in = 3, .n_out = 2 };
    const sz = nodeSize(g);
    var i: u8 = 0;
    while (i < g.n_in) : (i += 1) {
        const p = inPortPos(g, i);
        try testing.expectApproxEqAbs(g.pos.x, p.x, 1e-4); // Left edge
        try testing.expect(p.y > g.pos.y and p.y < g.pos.y + sz.y);
    }
    var j: u8 = 0;
    while (j < g.n_out) : (j += 1) {
        const p = outPortPos(g, j);
        try testing.expectApproxEqAbs(g.pos.x + NODE_W, p.x, 1e-4); // Right edge
        try testing.expect(p.y > g.pos.y and p.y < g.pos.y + sz.y);
    }
}

test "canvas: hitTestPort / hitTestCable" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 200, .y = 0 }, .n_in = 1, .n_out = 0 },
    };
    const edges = [_]Edge{.{ .src_handle = 0, .src_out = 0, .dst_handle = 1, .dst_in = 0 }};
    // Near node0's output port
    const op = outPortPos(nodes[0], 0);
    try testing.expect(hitTestPort(op, &nodes) != null);
    const pr = hitTestPort(op, &nodes).?;
    try testing.expectEqual(@as(Handle, 0), pr.handle);
    try testing.expect(!pr.is_input);
    // Near the cable midpoint
    const ip = inPortPos(nodes[1], 0);
    const mid = Vec2f{ .x = (op.x + ip.x) / 2, .y = (op.y + ip.y) / 2 };
    try testing.expectEqual(@as(?usize, 0), hitTestCable(mid, &nodes, &edges));
    // A point far from the cable does not hit
    try testing.expectEqual(@as(?usize, null), hitTestCable(.{ .x = mid.x, .y = mid.y + 100 }, &nodes, &edges));
}

test "canvas: hitTestToggle hits the toggle box and misses node body / outside" {
    const nodes = [_]NodeGeom{
        .{ .handle = 5, .pos = .{ .x = 100, .y = 50 }, .n_in = 1, .n_out = 1 },
    };
    const tp = togglePos(nodes[0]);
    const inside = Vec2f{ .x = tp.x + TOGGLE_SIZE / 2, .y = tp.y + TOGGLE_SIZE / 2 };
    try testing.expectEqual(@as(?Handle, 5), hitTestToggle(inside, &nodes));
    // Inside the node but outside the toggle (near the left edge).
    const node_body = Vec2f{ .x = nodes[0].pos.x + 5, .y = nodes[0].pos.y + 5 };
    try testing.expectEqual(@as(?Handle, null), hitTestToggle(node_body, &nodes));
    // Outside the node.
    try testing.expectEqual(@as(?Handle, null), hitTestToggle(.{ .x = 900, .y = 900 }, &nodes));
}

test "canvas: nodeSize grows for grid box (grid_rows>0) and matches gridBlockHeight" {
    const plain = NodeGeom{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 };
    const box = NodeGeom{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1, .grid_rows = 2 };
    try testing.expect(nodeSize(box).y > nodeSize(plain).y); // Extended by the grid row count
    // Matches the explicit formula (case where the grid height exceeds the port height); includes the n_out>0 band (MINI_H+MINI_GAP).
    const expect_h = TITLE_H + gridBlockHeight(2) + BODY_PAD + MINI_H + MINI_GAP;
    try testing.expectApproxEqAbs(expect_h, nodeSize(box).y, 1e-4);
}

test "canvas: nodeSize contains 1-row inline grid (drum standalone)" {
    const g = NodeGeom{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1, .grid_rows = 1 };
    const geom = gridGeometry(.{ .zoom = 1.0 }, g.pos);
    const last_y = geom.origin_y + geom.cell_h; // Bottom of row 0
    try testing.expect(last_y <= g.pos.y + nodeSize(g).y);
    // The max of port height and grid height (a 1-row grid is often shorter than the port height), plus the n_out>0 band.
    const port_h = TITLE_H + PORT_SPACING * 1.0 + BODY_PAD;
    const grid_h = TITLE_H + gridBlockHeight(1) + BODY_PAD;
    try testing.expectApproxEqAbs(@max(port_h, grid_h) + MINI_H + MINI_GAP, nodeSize(g).y, 1e-4);
}

test "canvas: nodeSize contains 4-row inline grid (bass standalone)" {
    const g = NodeGeom{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 3, .grid_rows = 4 };
    const geom = gridGeometry(.{ .zoom = 1.0 }, g.pos);
    // The bottom of row 3 is within the node's bottom edge
    const last_y = geom.origin_y + 3.0 * geom.row_pitch + geom.cell_h;
    try testing.expect(last_y <= g.pos.y + nodeSize(g).y);
    // For bass, the max of the n_out=3 port height and the 4-row grid height, plus the n_out>0 band.
    const port_h = TITLE_H + PORT_SPACING * 3.0 + BODY_PAD;
    const grid_h = TITLE_H + gridBlockHeight(4) + BODY_PAD;
    try testing.expectApproxEqAbs(@max(port_h, grid_h) + MINI_H + MINI_GAP, nodeSize(g).y, 1e-4);
}

test "canvas: gridGeometry is shared by macro box and standalone node positions" {
    const cam = Camera{ .pan = .{ .x = 12, .y = -4 }, .zoom = 1.5 };
    const pos = Vec2f{ .x = 160, .y = 470 };
    // The same adapter and input always yield the same cell rect (the macro/standalone distinction is meaningful only to the caller).
    const a = gridGeometry(cam, pos);
    const b = gridGeometry(cam, pos);
    try testing.expectEqual(a.origin_x, b.origin_x);
    try testing.expectEqual(a.origin_y, b.origin_y);
    try testing.expectEqual(a.cell_w, b.cell_w);
    try testing.expectEqual(a.cell_h, b.cell_h);
    try testing.expectEqual(a.step_pitch, b.step_pitch);
    try testing.expectEqual(a.row_pitch, b.row_pitch);
    // A representative cell center falls inside the box (same constants for standalone 1-row and macro 3-row)
    const cx = a.origin_x + a.cell_w * 0.5;
    const cy = a.origin_y + a.cell_h * 0.5;
    try testing.expect(cx > pos.x * cam.zoom + cam.pan.x);
    try testing.expect(cy > pos.y * cam.zoom + cam.pan.y);
}

test "canvas: resolveConnection direction rules (self-loop allowed, same-dir rejected)" {
    const out0 = PortRef{ .handle = 0, .is_input = false, .index = 0 };
    const in0 = PortRef{ .handle = 1, .is_input = true, .index = 0 };
    // out→in
    {
        const rc = resolveConnection(out0, in0).?;
        try testing.expectEqual(@as(Handle, 0), rc.src.handle);
        try testing.expectEqual(@as(Handle, 1), rc.dst.handle);
        try testing.expect(!rc.src.is_input and rc.dst.is_input);
    }
    // in->out (regardless of argument order, src is the output)
    {
        const rc = resolveConnection(in0, out0).?;
        try testing.expectEqual(@as(Handle, 0), rc.src.handle);
        try testing.expectEqual(@as(Handle, 1), rc.dst.handle);
    }
    // out-out / in-in are invalid
    try testing.expect(resolveConnection(out0, .{ .handle = 2, .is_input = false, .index = 0 }) == null);
    try testing.expect(resolveConnection(in0, .{ .handle = 2, .is_input = true, .index = 1 }) == null);
    // An out->in pair on the same node (a different port, i.e. a self-loop) is allowed
    {
        const s_out = PortRef{ .handle = 5, .is_input = false, .index = 0 };
        const s_in = PortRef{ .handle = 5, .is_input = true, .index = 1 };
        const rc = resolveConnection(s_out, s_in).?;
        try testing.expectEqual(@as(Handle, 5), rc.src.handle);
        try testing.expectEqual(@as(Handle, 5), rc.dst.handle);
    }
}

test "canvas: hitTestPalette inside/outside" {
    const buttons = [_]PaletteButton{
        .{ .kind_index = 0, .rect = .{ .x = 10, .y = 20, .w = 100, .h = 24 } },
        .{ .kind_index = 1, .rect = .{ .x = 10, .y = 50, .w = 100, .h = 24 } },
    };
    try testing.expectEqual(@as(?u8, 0), hitTestPalette(.{ .x = 50, .y = 30 }, &buttons));
    try testing.expectEqual(@as(?u8, 1), hitTestPalette(.{ .x = 50, .y = 60 }, &buttons));
    try testing.expectEqual(@as(?u8, null), hitTestPalette(.{ .x = 500, .y = 30 }, &buttons));
}

test "canvas: miniScopeRect sits inside the node's bottom edge" {
    const tl = Vec2f{ .x = 100, .y = 50 };
    const zoom: f32 = 1.0;
    // For a node with n_out>0, nodeSize() already includes the band, so it is passed through as sz directly.
    const g = NodeGeom{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 };
    const sz = nodeSize(g).scale(zoom);
    const r = miniScopeRect(tl, sz, zoom);
    try testing.expectApproxEqAbs(tl.x, r.x, 1e-4);
    try testing.expectApproxEqAbs(tl.y + sz.y - (MINI_H + MINI_GAP) * zoom, r.y, 1e-4);
    try testing.expectApproxEqAbs(MINI_W * zoom, r.w, 1e-4);
    try testing.expectApproxEqAbs(MINI_H * zoom, r.h, 1e-4);
    // It fits inside the node (does not spill past the bottom edge).
    try testing.expect(r.y >= tl.y);
    try testing.expect(r.y + r.h <= tl.y + sz.y + 1e-4);
    try testing.expect(r.x + r.w <= tl.x + sz.x + 1e-4);
}

test "canvas: miniScopeRect stays within node bounds across zoom range (0.25/0.5/4.0)" {
    const g = NodeGeom{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 };
    const tl = Vec2f{ .x = 200, .y = 150 };
    for ([_]f32{ 0.25, 0.5, 4.0 }) |zoom| {
        const sz = nodeSize(g).scale(zoom);
        const r = miniScopeRect(tl, sz, zoom);
        try testing.expect(r.x >= tl.x - 1e-3);
        try testing.expect(r.x + r.w <= tl.x + sz.x + 1e-3);
        try testing.expect(r.y >= tl.y - 1e-3);
        try testing.expect(r.y + r.h <= tl.y + sz.y + 1e-3);
    }
}

test "canvas: selectTapPorts — priority selected>hover>order, cap, zoom gate, n_out filter" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 2, .pos = .{ .x = 480, .y = 60 }, .n_in = 1, .n_out = 0 }, // No output -> not a candidate
    };
    const cam = Camera{ .zoom = 1.0 };
    const vw: f32 = 800;
    const vh: f32 = 400;
    var out: [8]Handle = undefined;
    // selected=1, hover=0 -> [1, 0, ...remaining order]. handle 2 is excluded since n_out=0.
    {
        const n = selectTapPorts(cam, vw, vh, &nodes, 1, 0, &out);
        try testing.expectEqual(@as(usize, 2), n);
        try testing.expectEqual(@as(Handle, 1), out[0]); // selected comes first
        try testing.expectEqual(@as(Handle, 0), out[1]); // hover comes next
    }
    // No selection/hover -> node list order (handle 2 excluded).
    {
        const n = selectTapPorts(cam, vw, vh, &nodes, null, null, &out);
        try testing.expectEqual(@as(usize, 2), n);
        try testing.expectEqual(@as(Handle, 0), out[0]);
        try testing.expectEqual(@as(Handle, 1), out[1]);
    }
    // zoom < MINI_ZOOM_MIN -> zero taps.
    {
        const n = selectTapPorts(.{ .zoom = 0.3 }, vw, vh, &nodes, 1, 0, &out);
        try testing.expectEqual(@as(usize, 0), n);
    }
    // cap: out length 1 -> 1 tap (selected takes priority).
    {
        var one: [1]Handle = undefined;
        const n = selectTapPorts(cam, vw, vh, &nodes, 1, 0, &one);
        try testing.expectEqual(@as(usize, 1), n);
        try testing.expectEqual(@as(Handle, 1), one[0]);
    }
}

test "canvas: findTriggerStart locks periodic signal to a rising zero crossing; free-runs otherwise" {
    // A sine wave with a 64-sample period, spanning 3 periods. The disp=64 display window aligns to a rising crossing.
    var sine: [192]f32 = undefined;
    for (&sine, 0..) |*s, i| s.* = @sin(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / 64.0);
    const start = findTriggerStart(&sine, 64);
    try testing.expect(start + 64 <= sine.len); // Slice is safe
    try testing.expect(sine[start - 1] < 0.0 and sine[start] >= 0.0); // Aligns to a rising crossing
    // A unipolar signal (never crosses zero) has no crossing -> falls back to the newest window (unlocked).
    var uni: [192]f32 = undefined;
    for (&uni, 0..) |*s, i| s.* = 0.5 + 0.4 * @sin(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / 64.0);
    try testing.expectEqual(uni.len - 64, findTriggerStart(&uni, 64));
    // disp>=n cannot lock -> 0 (the whole window is shown).
    try testing.expectEqual(@as(usize, 0), findTriggerStart(sine[0..32], 32));
}

test "canvas: selectTapPorts — offscreen node (out0 outside viewport) is not tapped" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 4000, .y = 60 }, .n_in = 0, .n_out = 1 }, // Off-screen
    };
    var out: [8]Handle = undefined;
    const n = selectTapPorts(.{ .zoom = 1.0 }, 800, 400, &nodes, null, null, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(Handle, 0), out[0]);
}

// ============================================================================
// selectTapPortsStable: a table-test group pinning down that switching hover/selected does not
// collaterally reset unrelated existing slots.
// ============================================================================

test "canvas: selectTapPortsStable — existing slots stay if still candidates (no collateral from hover changes)" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 2, .pos = .{ .x = 480, .y = 60 }, .n_in = 1, .n_out = 1 },
    };
    const cam = Camera{ .zoom = 1.0 };
    // Previous: slot0=handle0 (e.g. a node that was hovered).
    var prev = [_]?Handle{ 0, null, null };
    var out: [3]?Handle = undefined;
    // Even if hover now changes to handle2, handle0 still satisfies isTapCandidate, so it
    // stays in slot0, and handle2 is newly added into the empty slot (slot1).
    selectTapPortsStable(cam, 800, 400, &nodes, null, 2, &prev, &out);
    try testing.expectEqual(@as(?Handle, 0), out[0]); // Retained
    try testing.expectEqual(@as(?Handle, 2), out[1]); // New (hover)
}

test "canvas: selectTapPortsStable — both selected and hover show when both are new candidates" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 2, .pos = .{ .x = 480, .y = 60 }, .n_in = 1, .n_out = 1 },
    };
    const cam = Camera{ .zoom = 1.0 };
    var prev = [_]?Handle{ null, null, null };
    var out: [3]?Handle = undefined;
    selectTapPortsStable(cam, 800, 400, &nodes, 1, 2, &prev, &out);
    var has1 = false;
    var has2 = false;
    for (out) |m| {
        if (m) |h| {
            if (h == 1) has1 = true;
            if (h == 2) has2 = true;
        }
    }
    try testing.expect(has1);
    try testing.expect(has2);
}

test "canvas: selectTapPortsStable — with capacity 1, new selected replaces old hover" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 },
    };
    const cam = Camera{ .zoom = 1.0 };
    // Previous: slot0 = handle0 (assumed to have been occupied by the old hover). A capacity-1 test buffer.
    var prev = [_]?Handle{0};
    var out: [1]?Handle = undefined;
    // Now selected=handle1 (new), hover=null (the old hover is gone).
    selectTapPortsStable(cam, 800, 400, &nodes, 1, null, &prev, &out);
    try testing.expectEqual(@as(?Handle, 1), out[0]); // The old handle0 is evicted and the selection takes its place
}

test "canvas: selectTapPortsStable — when full, replaces both selected and hover (no double-write same slot)" {
    // A and B, which occupied slot0/slot1 previously, are now neither selected nor hover (i.e. they are at the
    // lowest priority and thus evictable). selected=C and hover=D are both new candidates, and since capacity is only 2 (zero free slots),
    // both go through the full-eviction path (step 4). If the slot used for the first eviction is immediately
    // re-chosen as the victim for the second eviction, the second slot (B) is left untouched while the first
    // eviction's result (C) is lost; `locked` prevents re-selecting the same slot to guard against this.
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 }, // A (old, neither selected nor hover)
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 }, // B (old, neither selected nor hover)
        .{ .handle = 2, .pos = .{ .x = 480, .y = 60 }, .n_in = 1, .n_out = 1 }, // C (new, selected)
        .{ .handle = 3, .pos = .{ .x = 700, .y = 60 }, .n_in = 1, .n_out = 1 }, // D (new, hover)
    };
    const cam = Camera{ .zoom = 1.0 };
    var prev = [_]?Handle{ 0, 1 }; // Previous: slot0=A, slot1=B (both still satisfy isTapCandidate this time)
    var out: [2]?Handle = undefined;
    selectTapPortsStable(cam, 800, 400, &nodes, 2, 3, &prev, &out);
    // Since neither A nor B is selected/hover, both are eviction targets, and C (selected) and D (hover)
    // each correctly land in a separate slot (a double-overwrite that loses one of C or D does not happen).
    var has_selected = false;
    var has_hover = false;
    for (out) |m| {
        if (m) |h| {
            if (h == 2) has_selected = true;
            if (h == 3) has_hover = true;
        }
    }
    try testing.expect(has_selected);
    try testing.expect(has_hover);
    // Neither A nor B (the old candidates) remains; both were evicted.
    for (out) |m| {
        if (m) |h| {
            try testing.expect(h != 0);
            try testing.expect(h != 1);
        }
    }
}

test "canvas: selectTapPortsStable — without selected/hover, ordinary candidates past cap do not replace existing slots (no frame-to-frame rotation)" {
    // The v1 fix alone (preventing a double overwrite of the same slot) is not enough: when there is no selected/hover
    // and the candidate count exceeds the cap, a perpetual rotation remained (frame A/B -> C/D, next frame C/D -> A/B, ...).
    // Ordinary candidates (neither selected nor hover) are
    // not given eviction rights and are dropped for that frame when no slot is free, so that existing slots stay
    // stable as long as selected/hover do not change.
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 }, // A
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 }, // B
        .{ .handle = 2, .pos = .{ .x = 480, .y = 60 }, .n_in = 1, .n_out = 1 }, // C (an ordinary candidate, neither selected nor hover)
        .{ .handle = 3, .pos = .{ .x = 700, .y = 60 }, .n_in = 1, .n_out = 1 }, // D (same as above)
    };
    const cam = Camera{ .zoom = 1.0 };
    var prev = [_]?Handle{ 0, 1 }; // Previous: slot0=A, slot1=B
    var out: [2]?Handle = undefined;
    // selected=null, hover=null. C and D are ordinary candidates but are not admitted since no slot is free.
    selectTapPortsStable(cam, 800, 400, &nodes, null, null, &prev, &out);
    try testing.expectEqual(@as(?Handle, 0), out[0]);
    try testing.expectEqual(@as(?Handle, 1), out[1]);

    // Simulating the "next frame" by calling again with out reused as prev yields the same result (no rotation).
    var prev2 = out;
    var out2: [2]?Handle = undefined;
    selectTapPortsStable(cam, 800, 400, &nodes, null, null, &prev2, &out2);
    try testing.expectEqual(@as(?Handle, 0), out2[0]);
    try testing.expectEqual(@as(?Handle, 1), out2[1]);
}

test "canvas: selectTapPortsStable vs resolveTapPort equivalent (handle change vs port-ID change are separate)" {
    // selectTapPortsStable itself does not resolve port IDs (that is the caller's, i.e. main.zig's, responsibility), so
    // here we pin down that "handle stabilization" and "detecting a change in the actual port ID" are separate axes,
    // via the slot handle transition patterns (covering both the case where the handle changes and the case where it doesn't),
    // confirmed at the selectTapPortsStable level. The republish decision on the actual port ID is
    // made by main.zig's updateViz via new_ports[]!=tap_ports[].
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 },
    };
    const cam = Camera{ .zoom = 1.0 };
    // Case A: the handle does not change (the same node stays selected) -> slot0 keeps the same handle.
    {
        var prev = [_]?Handle{0};
        var out: [1]?Handle = undefined;
        selectTapPortsStable(cam, 800, 400, &nodes, 0, null, &prev, &out);
        try testing.expectEqual(@as(?Handle, 0), out[0]);
    }
    // Case B: the handle changes (selected moves to a different node) -> slot0's handle changes to the new one.
    {
        var prev = [_]?Handle{0};
        var out: [1]?Handle = undefined;
        selectTapPortsStable(cam, 800, 400, &nodes, 1, null, &prev, &out);
        try testing.expectEqual(@as(?Handle, 1), out[0]);
    }
}

test "canvas: viewportContains — fit layout has zero offscreen at representative zoom" {
    // 3 nodes positioned so they fit on screen.
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 2, .n_out = 1 },
        .{ .handle = 2, .pos = .{ .x = 480, .y = 60 }, .n_in = 1, .n_out = 0 },
    };
    const edges = [_]Edge{
        .{ .src_handle = 0, .src_out = 0, .dst_handle = 1, .dst_in = 0 },
        .{ .src_handle = 1, .src_out = 0, .dst_handle = 2, .dst_in = 0 },
    };
    const vw: f32 = 800;
    const vh: f32 = 400;
    // All fit at zoom=1 (pan 0)
    {
        const oc = viewportContains(.{ .zoom = 1.0 }, vw, vh, &nodes, &edges);
        try testing.expectEqual(@as(u32, 0), oc.node);
        try testing.expectEqual(@as(u32, 0), oc.port);
        try testing.expectEqual(@as(u32, 0), oc.cable);
    }
    // Off-screen detection: panning far to the right pushes nodes off-screen -> offscreen>0
    {
        const oc = viewportContains(.{ .pan = .{ .x = 700, .y = 0 }, .zoom = 1.0 }, vw, vh, &nodes, &edges);
        try testing.expect(oc.node > 0 or oc.port > 0 or oc.cable > 0);
    }
}

test "canvas: inspector param row keeps value within content width even with a long label" {
    const avail: i32 = 260; // A typical inspector content width (PanelHost right extent minus padding)
    const longest_labels = [_]i32{
        8 * "cutoff_mod_oct (oct)".len,
        8 * "level_mod_depth".len,
        8 * "mod_octaves (oct)".len,
    };

    for (longest_labels) |label_w| {
        const row = inspectorParamRowLayout(avail, label_w);
        try testing.expectEqual(INSPECTOR_PARAM_VALUE_W, row.value_w);
        try testing.expect(row.track_w >= INSPECTOR_PARAM_TRACK_MIN);
        try testing.expectEqual(avail, row.total());
        try testing.expect(row.label_w <= label_w);
    }

    const short = inspectorParamRowLayout(avail, 8 * "base_hz (Hz)".len);
    try testing.expectEqual(@as(i32, @intCast(8 * "base_hz (Hz)".len)), short.label_w);
    try testing.expectEqual(avail, short.total());
}

// ============================================================================
// Rectangle selection: normalization and intersection checks
// ============================================================================

test "canvas: normalizeWorldRect forward and reverse drag" {
    const a = Vec2f{ .x = 10, .y = 20 };
    const b = Vec2f{ .x = 40, .y = 50 };
    const fwd = normalizeWorldRect(a, b);
    try testing.expectApproxEqAbs(@as(f32, 10), fwd.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 20), fwd.y, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 30), fwd.w, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 30), fwd.h, 1e-5);
    const rev = normalizeWorldRect(b, a);
    try testing.expectApproxEqAbs(fwd.x, rev.x, 1e-5);
    try testing.expectApproxEqAbs(fwd.y, rev.y, 1e-5);
    try testing.expectApproxEqAbs(fwd.w, rev.w, 1e-5);
    try testing.expectApproxEqAbs(fwd.h, rev.h, 1e-5);
}

test "canvas: rectsIntersectPositive containment / partial / miss / edge / zero-size" {
    const node = WorldRect{ .x = 100, .y = 100, .w = 120, .h = 80 };
    // Full containment
    try testing.expect(rectsIntersectPositive(WorldRect{ .x = 90, .y = 90, .w = 200, .h = 200 }, node));
    try testing.expect(rectsIntersectPositive(node, WorldRect{ .x = 110, .y = 110, .w = 20, .h = 20 }));
    // Partial intersection
    try testing.expect(rectsIntersectPositive(WorldRect{ .x = 200, .y = 120, .w = 50, .h = 50 }, node));
    // No intersection
    try testing.expect(!rectsIntersectPositive(WorldRect{ .x = 300, .y = 300, .w = 10, .h = 10 }, node));
    // Boundary touch only (zero area) -> miss
    try testing.expect(!rectsIntersectPositive(WorldRect{ .x = 220, .y = 100, .w = 10, .h = 80 }, node));
    try testing.expect(!rectsIntersectPositive(WorldRect{ .x = 100, .y = 180, .w = 120, .h = 10 }, node));
    // zero-size → miss
    try testing.expect(!rectsIntersectPositive(WorldRect{ .x = 100, .y = 100, .w = 0, .h = 80 }, node));
    try testing.expect(!rectsIntersectPositive(WorldRect{ .x = 150, .y = 140, .w = 0, .h = 0 }, node));
}

test "canvas: nodeWorldBBox matches nodeSize" {
    const g = NodeGeom{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 2, .n_out = 1 };
    const bb = nodeWorldBBox(g);
    const sz = nodeSize(g);
    try testing.expectApproxEqAbs(g.pos.x, bb.x, 1e-5);
    try testing.expectApproxEqAbs(g.pos.y, bb.y, 1e-5);
    try testing.expectApproxEqAbs(sz.x, bb.w, 1e-5);
    try testing.expectApproxEqAbs(sz.y, bb.h, 1e-5);
}
