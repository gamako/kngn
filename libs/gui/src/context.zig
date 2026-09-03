// Context: bundles input + ID stack + interaction state + drawing phases + arena + font + layout.
// Frame lifecycle (beginFrame / endFrame) and the starting point for widget behavior.
//
// Current contracts for lifecycle, sync hit-test, and clip visibility follow.
// Keep these comments aligned with the implementation below.
// Do not weaken the prohibitions (e.g. no trim inside the widget-build loop).
//
// Lifecycle contract (Context as the contract guardian + layout):
//   beginFrame(w,h): arena.reset → input/id_stack/state.beginFrame → per_id_state.beginFrame
//                    → the main draw list reset(w,h)  ※ w/h are logical size (not the physical fb)
//                    → allocate the implicit layout-tree root on the arena (not yet measure/place this frame)
//                    → apply input staged since the last frame (arrival order, edges already cleared)
//   input:           pushEvent / setComposition may be called at any point in the loop. Inside a
//                    frame they apply immediately; outside one they are staged and applied by the
//                    next beginFrame, so forwarding platform events before opening the frame is
//                    just as correct as forwarding them after (see StagedInput in input.zig).
//   widget calls: sync hit-test against the previous-frame rect_cache (never the layout rects still under construction)
//   endFrame():      layoutTree (measureWidths → placeWidths → wrapText →
//                    measureHeights → placeHeights) → rect_cache.clearRetainingCapacity
//                    → updateRectCache → emitNode (emit draw cmds) → final_overlay
//                    → focus cleanup → active cleanup → PerIdStateStore.trim (frame boundary only)
//                    No hit-test here. The new rect_cache is referenced from the next frame after this endFrame completes.
//                    Does not touch the arena (Context is the contract guardian).
//                    After endFrame, the post-frame draw list / id_stack / state / the layout tree stay
//                    valid until the next beginFrame. The rect cache (GPA-owned) stays valid until the next endFrame.
//                    PerIdStateStore LRU trim runs only at the end of endFrame (never during widget build).
//
// Sync hit-test contract:
//   At call time a widget runs buttonBehavior against the "previous-frame rect cache" (getNodeRect / rect_cache)
//   and returns ButtonResult synchronously. There is no second hit-test after endFrame.
//   During a drag that changes layout, draw uses the new layout and hit-test uses the old — one frame of lag
//   (current contract; invisible for static layouts).
//
// Clip / hit-test visibility contract:
//   - cached `clip` is the effective clip reflecting ancestor clip_children (same bounds as draw pushClip).
//   - A node's own clip_children applies to its children, not itself, and clips to the
//     content box (border-box minus padding) so padding is outside the visible child region.
//   - clip_children=false overflow is allowed for both draw and hit-test (outside the parent rect but inside ancestor clip).
//   - Outside clip_children=true is forbidden for both draw and hit-test.
//   - A zero-size effective clip is invisible and not hit-testable.
//   - The predicate is pointHitsVisible(rect, clip, p). Active drag capture is kept even outside clip;
//     only the click on release must land inside the visible region.
//
// Draw emit order: layout cmds are appended after any commands the caller pushed through mainDrawList
// during the frame (= layout UI draws on top).

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("geom.zig");
const color_mod = @import("color.zig");
const animation_mod = @import("animation.zig");
const draw = @import("draw.zig");
const font_mod = @import("font.zig");
const id_mod = @import("id.zig");
const input_mod = @import("input.zig");
const state_mod = @import("state.zig");
const layout = @import("layout.zig");
const layout_sanity_probe = @import("layout_sanity_probe.zig");
const text_wrap_mod = @import("text_wrap.zig");
const style_mod = @import("style.zig");
// Mutual import with widgets.zig (widgets take *Context; Zig import cycles are legal).
// Decl aliases inside the Context struct provide `ctx.button(...)` method syntax.
const widgets = @import("widgets.zig");
// popup.zig uses the same mutual-import pattern.
const popup_mod = @import("popup.zig");
const stepgrid_mod = @import("stepgrid.zig");
// dnd.zig uses the same mutual-import pattern (Context.drag is declared here; the state machine lives there).
const dnd_mod = @import("dnd.zig");
const table_mod = @import("table.zig");

pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Vec2f = input_mod.Vec2f;
const layer_types = @import("layer_types.zig");
pub const LayerKey = layer_types.LayerKey;
pub const LayerInputPolicy = layer_types.LayerInputPolicy;
pub const LayerSpec = layer_types.LayerSpec;
pub const LayerPlacement = layer_types.LayerPlacement;
pub const AnchorSource = layer_types.AnchorSource;

/// The most layers that may be registered in one frame. Small and fixed: a screen
/// showing more than a handful of menus, dialogs and tooltips at once has a different problem
/// than a capacity limit. Overflow is a contract failure, not a silent drop — a menu that just
/// does not appear is far harder to diagnose than one that says why.
pub const max_layers: usize = 32;

/// The state of one layer in the current frame.
pub const LayerStatus = enum {
    /// Its anchor has not been resolved yet this frame.
    waiting,
    /// Placed; its rect cache entries are written and it will be emitted.
    placed,
    /// Its anchor is not in this frame, or the layer it anchors to is itself missing. Not
    /// emitted and not cached: drawing it would mean drawing at a coordinate from a frame
    /// that no longer describes the screen.
    missing,
};

/// One layer in the current frame. Lives as long as the frame.
pub const LayerRecord = struct {
    key: LayerKey,
    z: i32,
    /// Registration order, which breaks ties between equal `z` the way sibling order already
    /// breaks ties between boxes.
    serial: u32,
    root_order: u16 = 0,
    root: *layout.Node,
    placement: LayerPlacement,
    status: LayerStatus,
    /// Whether this layer's boxes join the rect cache — and so the one explicit-id namespace,
    /// and so what an `.id` anchor can point at.
    cache: bool,
    /// Index in `layers` of the layer this one anchors into, when its anchor id belongs to
    /// one. Null for a `.point` anchor or an anchor in the main tree.
    depends_on: ?usize,
    input: LayerInputPolicy,
    dismiss_on_outside: bool,
};

/// What survives between frames for one layer. A `LayerRecord` describes a frame; this
/// describes the slot, and is what makes "was this layer on screen last frame" answerable —
/// the question first-visible suppression and outside-press dismissal are both built on.
pub const LayerSlot = struct {
    key: LayerKey,
    z: i32 = 0,
    serial: u32 = 0,
    root_order: u16 = 0,
    input: LayerInputPolicy = .none,
    dismiss_on_outside: bool = false,
    prev_root_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    was_placed: bool = false,
};

/// The previous-frame route selected at beginFrame. A null key means that main owns input.
const LayerRoute = struct {
    frontmost_key: ?LayerKey = null,
};

/// O(1) input permissions for the current marker scope. Widget code reads these flags rather
/// than searching the layer tree or comparing z values for every widget.
const LayerScope = struct {
    layer_key: ?LayerKey = null,
    pointer_enabled: bool = true,
    keyboard_enabled: bool = true,
    focus_enabled: bool = true,
    wheel_enabled: bool = true,
    previous_geometry_available: bool = true,
    route_active: bool = false,
    root_order: u16 = 0,
};

const FocusScopeEntry = struct {
    layer_key: ?LayerKey = null,
    enabled: bool = true,
};

/// A main-tree control that may receive a pointer click while its own menu layer owns the route.
/// Command targets are explicit widgets, not a subtree-wide escape hatch. Their geometry is
/// still read from the previous-frame rect cache, just like every other synchronous hit-test.
const CommandTarget = struct {
    id: Id,
    route_key: LayerKey,
};
pub const Color = color_mod.Color;
pub const Id = id_mod.Id;
pub const IdStack = id_mod.IdStack;
pub const Input = input_mod.Input;
pub const InputEvent = input_mod.InputEvent;
pub const InteractionState = state_mod.InteractionState;
pub const DrawList = draw.DrawList;
pub const BitmapFont = font_mod.BitmapFont;
pub const Font = font_mod.Font;
pub const BoxConfig = layout.BoxConfig;
pub const LayoutSanityResult = layout_sanity_probe.Result;
pub const Style = style_mod.Style;
pub const AnimationStyle = style_mod.AnimationStyle;
pub const WidgetStyle = style_mod.WidgetStyle;
pub const TweenState = animation_mod.TweenState;
pub const AnimationState = animation_mod.AnimationState;
pub const PerIdState = state_mod.PerIdState;
// Popup / context menu. Implementation and doc comments live in popup.zig.
pub const PopupState = popup_mod.PopupState;
pub const PopupItem = popup_mod.PopupItem;
pub const PopupResult = popup_mod.PopupResult;
pub const PopupMenuOpts = popup_mod.PopupMenuOpts;
pub const DialogState = popup_mod.DialogState;
pub const DialogOptions = popup_mod.DialogOptions;
pub const DialogResult = popup_mod.DialogResult;
pub const stepgrid = stepgrid_mod;
// Cross-widget drag-and-drop. Implementation and doc comments live in dnd.zig.
pub const DragPayload = dnd_mod.DragPayload;
pub const DragState = dnd_mod.DragState;

/// Entry in the rect cache.
/// `clip` is the effective clip after intersecting ancestor `clip_children` (matches draw pushClip bounds).
/// This node's own `clip_children` is not stored here; it only affects the child_clip passed downward.
/// `buttonBehavior` / TextInput / SelectableLabel share the `pointHitsVisible(rect, clip, p)` predicate.
pub const CachedRect = struct {
    rect: Rect,
    clip: Rect,
    measured_w: i32 = 0,
    measured_h: i32 = 0,
    /// Recorded content extent after place. -1 = not recorded (leaf / place not run).
    content_w: i32 = -1,
    content_h: i32 = -1,
    /// Clamped `.fixed` declaration, or -1 when the axis is not `.fixed`.
    declared_w: i32 = -1,
    declared_h: i32 = -1,

    /// Scroll-range size: declared fixed (clamped) → recorded extent → measured.
    pub fn scrollContentSize(self: CachedRect) Vec2 {
        return .{
            .x = pickContentLen(self.declared_w, self.content_w, self.measured_w),
            .y = pickContentLen(self.declared_h, self.content_h, self.measured_h),
        };
    }
};

fn pickContentLen(declared: i32, extent: i32, measured: i32) i32 {
    if (declared >= 0) return declared;
    if (extent >= 0) return extent;
    return measured;
}

/// Options for `Context.text`. `color = null` uses `style.text`. `max_lines = 0`
/// means unlimited for `.visible` / `.clip`, and 1 for `.ellipsis`.
pub const TextOptions = struct {
    color: ?Color = null,
    font: ?Font = null,
    wrap: bool = false,
    max_lines: u16 = 0,
    overflow: layout.Overflow = .visible,
};

/// Internal state carried across a scroll area's begin→end. begin computes from the previous-frame cache,
/// pushes onto scroll_stack; end pops and builds the scrollbar.
///
/// Wheel consumption: previous-frame geometry decides *who* is first (the chain head =
/// deepest area under the cursor, ties at the same depth broken by reverse end-order).
/// Only that head consumes wheel in `beginScrollArea`. Other areas that have a
/// previous-frame viewport consume leftover wheel in `endScrollArea` (innermost
/// first, so inner-edge remainder still propagates outward). An area with no
/// previous-frame rect (its first frame) is not a wheel target; it becomes one
/// on the next frame. Amounts are always computed from the area's current
/// `scroll` and content size; the registry never stores a previous-frame max.
/// Hit-testing uses the cursor sealed with the chain, not a later `mouse_pos`.
pub const ScrollState = struct {
    bar_thickness: i32,
    track_col: Color,
    thumb_col: Color,
    thumb_hot: Color,
    thumb_active: Color,
    need_v: bool,
    need_h: bool,
    v_off: i32,
    v_len: i32,
    h_off: i32,
    h_len: i32,
    vthumb_id: Id,
    hthumb_id: Id,
    /// Viewport widget id (`beginScrollArea`'s `id`). Used to record the area and
    /// to match the wheel-chain head.
    viewport_id: Id = 0,
    /// Caller-owned scroll amount (wheel target)
    scroll: *Vec2f = undefined,
    /// Previous-frame viewport rect (for hit-testing; null if unsettled)
    viewport_rect: ?Rect = null,
    max_x: i32 = 0,
    max_y: i32 = 0,
    wheel_px: f32 = 32.0,
    vp_w: i32 = 0,
    vp_h: i32 = 0,
    /// This frame's viewport layout node (scroll_x/y applied after wheel)
    viewport_node: ?*layout.Node = null,
};

/// Previous-frame ScrollArea entry used only to decide wheel order (never amount).
/// `rect` is the viewport settled at the previous `endFrame`. `serial` is the
/// previous frame's `endScrollArea` arrival index (0 = first to end).
pub const ScrollAreaRecord = struct {
    id: Id,
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    depth: u16 = 0,
    /// Root order: 0 for main, increasing with the visual layer root order.
    root_order: u16 = 0,
    serial: u16 = 0,
};

/// Pick the wheel-chain head from previous-frame geometry: frontmost root whose viewport contains
/// `mouse`, then deepest record, with reverse end-order as the final tie-break. An empty / zero-size
/// rect never matches.
///
/// This is the same scan order as end-time LIFO for nested areas, made unique
/// for same-depth overlapping siblings. Amounts are not decided here.
pub fn pickWheelChainHead(records: []const ScrollAreaRecord, mouse: Vec2) Id {
    var best_id: Id = 0;
    var best_root_order: i32 = -1;
    var best_depth: i32 = -1;
    var best_serial: i32 = -1;
    for (records) |rec| {
        if (rec.rect.w == 0 or rec.rect.h == 0) continue;
        const rw: i32 = @intCast(rec.rect.w);
        const rh: i32 = @intCast(rec.rect.h);
        const inside = mouse.x >= rec.rect.x and mouse.x < rec.rect.x + rw and
            mouse.y >= rec.rect.y and mouse.y < rec.rect.y + rh;
        if (!inside) continue;
        const nearer_root = @as(i32, rec.root_order) > best_root_order;
        const same_root = @as(i32, rec.root_order) == best_root_order;
        const deeper = same_root and @as(i32, rec.depth) > best_depth;
        const later = same_root and
            @as(i32, rec.depth) == best_depth and @as(i32, rec.serial) > best_serial;
        if (nearer_root or deeper or later) {
            best_id = rec.id;
            best_root_order = rec.root_order;
            best_depth = rec.depth;
            best_serial = rec.serial;
        }
    }
    return best_id;
}

/// Builder for a custom tooltip subtree. Same function-pointer + opaque-context
/// shape as `CustomDrawFn`. Called only while a tooltip is showing (hover delay
/// already met). The builder may use layout and draw-command APIs; interactive
/// and state-mutating APIs are a lifecycle violation (see `requireInteractiveAllowed`).
pub const TooltipBuildFn = *const fn (build_ctx: *anyopaque, ctx: *Context) void;

/// Overlay candidate published at endFrame. At most one per frame; last writer wins.
pub const TooltipCandidate = union(enum) {
    text: []const u8,
    custom: *layout.Node,
};

/// One row's two fixed-width cells, held so `endSliderGroup` can widen them once the group's
/// widest label and widest value are known. Allocated on the frame arena and linked in build order.
pub const SliderGroupCell = struct {
    label_node: *layout.Node,
    value_node: *layout.Node,
    next: ?*SliderGroupCell = null,
};

/// Internal state carried across a slider group's begin→end.
///
/// Column widths are settled inside the frame that draws them, not carried over from the previous
/// one: each row registers its cells here while it builds, and `endSliderGroup` writes the group's
/// maxima back into every cell. Layout does not run until `endFrame`, so the widths every row is
/// finally measured and placed with are this frame's. No row is ever drawn misaligned, not even the
/// first frame of a group or the frame its label set changes.
pub const SliderGroupState = struct {
    column_gap: i32,
    cells: ?*SliderGroupCell = null,
    last: ?*SliderGroupCell = null,
    label_w: i32 = 0,
    value_w: i32 = 0,
};

const DrawPhase = enum {
    idle,
    main_build,
    display_only_build,
    main_emit,
    layer_emit,
    final_overlay,
};

const DrawAccess = enum {
    main,
    post_frame,
};

const DrawListHolder = struct {
    list: DrawList,
    phase: DrawPhase = .idle,
    display_only_depth: u32 = 0,
};

fn drawAccessAllowed(phase: DrawPhase, access: DrawAccess) bool {
    return switch (phase) {
        .idle, .final_overlay => access == .post_frame,
        .main_build => access == .main,
        .display_only_build, .main_emit, .layer_emit => false,
    };
}

pub const Context = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    input: Input,
    id_stack: IdStack,
    state: InteractionState = .{},
    per_id_state: state_mod.PerIdStateStore = .{},
    draw_holder: DrawListHolder,
    font: Font,
    /// Non-null only when `font` is the deterministic default proxy. Tier variants borrow this
    /// family; custom bitmap or outline fonts stay untouched by tier size/weight.
    default_family: ?*font_mod.OutlineFontFamily = null,
    screen_w: u32 = 0,
    screen_h: u32 = 0,
    frame_index: u64 = 0,
    now_s: f64 = 0,
    /// Implicit root of the layout tree (allocated on the arena in beginFrame)
    layout_root: ?*layout.Node = null,
    /// Layers registered this frame, and the slots that outlive the frame. Fixed arrays
    /// rather than lists on the frame arena: a list whose storage the arena reset frees but
    /// whose capacity survives is a dangling pointer waiting for the next append.
    layers: [max_layers]LayerRecord = undefined,
    layers_len: usize = 0,
    layer_slots: [max_layers]LayerSlot = undefined,
    layer_slots_len: usize = 0,
    /// Explicit IDs owned by cache-enabled layer roots, indexed once before placement.
    /// This replaces a recursive search for every layer anchor resolution. The table is retained
    /// across frames but is touched only on frames that register at least one layer.
    layer_owner_map: std.AutoHashMapUnmanaged(Id, usize) = .empty,
    /// Input route latched from the previous frame's placed layer slots.
    layer_route: LayerRoute = .{},
    /// Outside dismissal is an edge result, not a close side effect. It is stable for the frame.
    dismissed_layer_key: ?LayerKey = null,
    /// Scope stack only changes at layer markers; ordinary boxes and widgets read one current
    /// scope without a tree walk or allocation.
    layer_scope_stack: [max_layers]LayerScope = undefined,
    layer_scope_depth: usize = 0,
    current_layer_scope: LayerScope = .{},
    /// Main-tree command targets registered by menuBar for the current frame. These are only
    /// eligible when the named menu layer is the previous-frame route owner and the press is
    /// outside that layer's previous root rect.
    command_targets: [max_layers]CommandTarget = undefined,
    command_targets_len: usize = 0,
    /// beginBox / endBox cursor (current parent)
    layout_current: ?*layout.Node = null,
    /// Layout sanity is opt-in; the result is copied out of the frame arena after the tree scan.
    layout_sanity_enabled: bool = false,
    layout_sanity_result: layout_sanity_probe.Result = .{},
    /// Explicit-ID (cfg.id != 0) node id → {rect, clip}. GPA-owned, survives across frames, and
    /// is updated only in endFrame (first half of the frame still holds previous-frame values = sync hit-test contract).
    rect_cache: std.AutoHashMapUnmanaged(Id, CachedRect) = .empty,
    /// Widgets that took part in keyboard focus traversal this frame, in submission order —
    /// which is draw order, so Tab walks the interface the way it looks. Cleared every frame with
    /// the capacity kept, so a steady interface reallocates nothing after the first frame.
    focus_order: std.ArrayList(Id) = .empty,
    /// Scope metadata parallel to `focus_order`. Inactive entries remain recorded so the
    /// resolver can preserve the main focus while a modal route owns the current frame.
    focus_scope_order: std.ArrayList(FocusScopeEntry) = .empty,
    /// A Tab press waiting to be resolved at the end of the frame, once `focus_order` is complete.
    focus_move: enum { none, next, prev } = .none,
    /// The text fields submitted this frame, enabled ones only. `focus_order` records every
    /// focusable as one flat list, so the focus it resolves cannot say *what kind* of widget it
    /// landed on; this is the one distinction the framework has to draw, because a native IME is
    /// switched on for a text field and for nothing else.
    ///
    /// Recorded where the structure is built rather than searched for where it is read: a tree
    /// with no text field clears an empty list and compares one id against zero, and allocates
    /// and walks nothing. Cleared every frame with the capacity kept, like `focus_order`.
    text_input_ids: std.ArrayList(Id) = .empty,
    /// The text field that held the focus when the last frame finished, or 0. Written once per
    /// frame in `endFrame`, after the focus has settled. See `wantsTextInput`.
    focused_text_input_id: Id = 0,
    focused_text_input_layer_key: ?LayerKey = null,
    /// Main focus remembered while a modal route temporarily owns the interface.
    saved_main_focus_id: Id = 0,
    saved_main_text_input_id: Id = 0,
    focused_layer_key: ?LayerKey = null,
    /// Generic layer input-gate contribution latched at beginFrame.
    latched_layer_text_input: bool = false,
    /// Scroll-area begin→end state stack (supports nesting). Not on the arena (push/pop within the frame).
    scroll_stack: std.ArrayList(ScrollState) = .empty,
    /// Unconsumed wheel delta for the frame (seeded from input.scroll_delta at the first wheel apply).
    /// Each ScrollArea consumes only what it could move; remainder at an edge propagates outward.
    wheel_remaining: Vec2f = .{},
    wheel_remaining_seeded: bool = false,
    /// Previous-frame ScrollArea geometry (order only). Swapped with `scroll_areas_cur` in beginFrame.
    scroll_areas_prev: std.ArrayList(ScrollAreaRecord) = .empty,
    scroll_area_layers_prev: std.ArrayList(?LayerKey) = .empty,
    /// This frame's ScrollArea records, written in `endScrollArea` and given settled rects in endFrame.
    scroll_areas_cur: std.ArrayList(ScrollAreaRecord) = .empty,
    scroll_area_layers_cur: std.ArrayList(?LayerKey) = .empty,
    /// Whether `ensureWheelChain` has sealed this frame's chain head.
    wheel_chain_ready: bool = false,
    /// Viewport id of the chain head (0 = none). Only this area consumes wheel in begin.
    wheel_chain_head: Id = 0,
    /// Cursor used for every wheel hit-test this frame. Sealed with the chain
    /// so a later `pushEvent(mouse_move)` cannot retarget consumption.
    wheel_chain_mouse: Vec2 = .{ .x = 0, .y = 0 },
    /// Shared widget style. Caller may rewrite directly (no push/pop).
    style: Style,
    /// At most one current or fading hover and press widget is woken each frame.
    animation_wake_hover: Id = 0,
    animation_wake_press: Id = 0,
    /// Frame-local presence markers used to drop wake IDs for widgets absent from the tree.
    animation_seen_hover: Id = 0,
    animation_seen_press: Id = 0,
    // ── tooltip. No PerIdStateStore; at most one candidate at a time.
    // Across frames: hover tracking (id / start time / rect). Frame-local fields reset in beginFrame.
    /// Widget id under continuous hover (0 = not tracking).
    tooltip_hover_id: Id = 0,
    /// Continuous-hover start time (`now()` / beginFrameAt virtual time).
    tooltip_hover_start_s: f64 = 0,
    /// Rect at continuous-hover start (movement breaks continuity).
    tooltip_hover_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Whether tooltip() or tooltipBox() refreshed the hover target this frame
    /// (suppresses unbuilt stale overlays).
    tooltip_hover_refreshed: bool = false,
    /// Last interactive widget (updated by behaviorFromCache; frame-local).
    tooltip_last_id: Id = 0,
    tooltip_last_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    tooltip_last_hovered: bool = false,
    /// Candidate emitted at this frame's endFrame (null if not yet due). Last writer wins.
    tooltip_candidate: ?TooltipCandidate = null,
    tooltip_candidate_anchor: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// This-frame custom-tooltip work. Reset in beginFrame.
    /// Hover checks run every frame; build and measure/place run only while a custom tooltip shows.
    tooltip_builder_calls: u32 = 0,
    tooltip_layout_calls: u32 = 0,
    /// When true, `allocator()` wraps the frame arena and records alloc count / peak bytes.
    /// Off by default (production path). The tooltip bench turns this on.
    track_frame_arena: bool = false,
    frame_arena_allocs: u32 = 0,
    frame_arena_live: usize = 0,
    frame_arena_peak: usize = 0,
    /// Frame-local IME composition (preedit) state. Cleared in beginFrame;
    /// the app sets it every frame via setComposition before widget calls.
    composition: input_mod.CompositionState = .{},
    /// Input pushed while no frame was open, waiting for the next beginFrame to apply it.
    /// See `StagedInput` in input.zig for the contract.
    staged_input: input_mod.StagedInput = .{},
    /// Nesting depth of `beginDisabled`/`endDisabled` (0 = not disabled). A scope, not a per-call
    /// option, because several widgets (checkbox/toggle/radio/textInputId) take no options struct
    /// today; wrapping a group of widgets is also the common case ("disable this whole section").
    disabled_depth: u32 = 0,
    // ── drag-and-drop. At most one drag in flight UI-wide (see dnd.zig's doc comment for the
    // armed→dragging lifecycle). null = no drag and no armed press.
    drag: ?DragState = null,
    /// Whether `dragSource` was called this frame for `drag.?.source_id` (frame-local; reset in
    /// beginFrame). Lets endFrame cancel an `armed` drag whose source widget stopped being built,
    /// instead of leaving it stuck (see dnd.zig).
    drag_submitted_this_frame: bool = false,
    /// The slider group `beginSliderGroup` opened, if one is open. Groups do not nest.
    slider_group: ?SliderGroupState = null,
    /// The table `beginTable` opened, if one is open. Tables do not nest.
    table: ?table_mod.TableState = null,

    // ── Widget layer. Implementations live in widgets.zig (aliases for method syntax) ──
    pub const button = widgets.button;
    pub const buttonEx = widgets.buttonEx;
    pub const buttonId = widgets.buttonId;
    pub const commandButtonId = widgets.commandButtonId;
    pub const colorSwatch = widgets.colorSwatch;
    pub const colorSwatchEx = widgets.colorSwatchEx;
    pub const colorSwatchId = widgets.colorSwatchId;
    // iconButton
    pub const iconButton = widgets.iconButton;
    pub const iconButtonId = widgets.iconButtonId;
    // Slider
    pub const sliderI32 = widgets.sliderI32;
    pub const sliderI32Id = widgets.sliderI32Id;
    pub const sliderF32 = widgets.sliderF32;
    pub const sliderF32Id = widgets.sliderF32Id;
    // HSV color picker
    pub const svSquare = widgets.svSquare;
    pub const svSquareId = widgets.svSquareId;
    pub const hueBar = widgets.hueBar;
    pub const hueBarId = widgets.hueBarId;

    pub const imageBox = widgets.imageBox;
    // Checkbox / Toggle(switch) / Radio (bool toggles)
    pub const checkbox = widgets.checkbox;
    pub const checkboxEx = widgets.checkboxEx;
    pub const checkboxId = widgets.checkboxId;
    pub const checkboxIdEx = widgets.checkboxIdEx;
    pub const toggle = widgets.toggle;
    pub const toggleEx = widgets.toggleEx;
    pub const toggleId = widgets.toggleId;
    pub const toggleIdEx = widgets.toggleIdEx;
    pub const radio = widgets.radio;
    pub const radioEx = widgets.radioEx;
    pub const radioId = widgets.radioId;
    pub const radioIdEx = widgets.radioIdEx;
    // Collapsible
    pub const beginCollapsible = widgets.beginCollapsible;
    pub const endCollapsible = widgets.endCollapsible;
    // Tabs (selected-section semantics)
    pub const tabId = widgets.tabId;
    // Listbox (single selection + Up/Down keyboard navigation)
    pub const pollListNav = widgets.pollListNav;
    pub const beginListboxRow = widgets.beginListboxRow;
    pub const endListboxRow = widgets.endListboxRow;
    // Ellipsis
    pub const ellipsizeText = widgets.ellipsizeText;
    pub const labelEllipsis = widgets.labelEllipsis;
    // Form row
    pub const beginFormRow = widgets.beginFormRow;
    pub const endFormRow = widgets.endFormRow;
    // Separator
    pub const separator = widgets.separator;
    // Slider group (label / track / value columns shared by the rows inside)
    pub const beginSliderGroup = widgets.beginSliderGroup;
    pub const endSliderGroup = widgets.endSliderGroup;
    // Column table (sticky header, shared column widths)
    pub const beginTable = table_mod.beginTable;
    pub const endTable = table_mod.endTable;
    pub const tableHeaderRow = table_mod.tableHeaderRow;
    pub const beginTableRow = table_mod.beginTableRow;
    pub const endTableRow = table_mod.endTableRow;
    pub const beginTableCell = table_mod.beginTableCell;
    pub const endTableCell = table_mod.endTableCell;
    // read-only text selection
    pub const selectableLabel = widgets.selectableLabel;
    pub const selectableLabelId = widgets.selectableLabelId;
    // single-line editable text
    pub const textInputId = widgets.textInputId;
    // Splitter (pane boundary)
    pub const splitter = widgets.splitter;
    // Vertical/horizontal scroll region
    pub const beginScrollArea = widgets.beginScrollArea;
    pub const endScrollArea = widgets.endScrollArea;
    // Fixed-row virtual list (thin helper on ScrollArea)
    pub const beginVirtualList = widgets.beginVirtualList;
    pub const endVirtualList = widgets.endVirtualList;
    pub const virtualScrollToRow = widgets.virtualScrollToRow;
    pub const popupMenu = popup_mod.popupMenu;
    pub const popupMenuEx = popup_mod.popupMenuEx;
    pub const dialog = popup_mod.dialog;
    pub const popupMenuStacked = popup_mod.popupMenuStacked;
    // Cross-widget drag-and-drop. Implementation and contract: see dnd.zig.
    pub const dragSource = dnd_mod.dragSource;
    pub const dropTarget = dnd_mod.dropTarget;
    pub const isDragging = dnd_mod.isDragging;
    pub const dragPayload = dnd_mod.dragPayload;
    pub const dragPosition = dnd_mod.dragPosition;
    pub const finishDrag = dnd_mod.finishDrag;
    pub const cancelDrag = dnd_mod.cancelDrag;

    pub fn init(gpa: Allocator, font: Font) Context {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .input = Input.init(gpa),
            .id_stack = IdStack.init(gpa),
            .draw_holder = .{ .list = DrawList.init(gpa) },
            .font = font,
            .default_family = if (font_mod.isDefaultFont(font)) font_mod.defaultFontFamily() else null,
            .style = style_mod.defaultStyle(),
        };
    }

    pub fn deinit(self: *Context) void {
        self.rect_cache.deinit(self.gpa);
        self.layer_owner_map.deinit(self.gpa);
        self.per_id_state.deinit(self.gpa);
        self.focus_order.deinit(self.gpa);
        self.focus_scope_order.deinit(self.gpa);
        self.text_input_ids.deinit(self.gpa);
        self.scroll_stack.deinit(self.gpa);
        self.scroll_areas_prev.deinit(self.gpa);
        self.scroll_area_layers_prev.deinit(self.gpa);
        self.scroll_areas_cur.deinit(self.gpa);
        self.scroll_area_layers_cur.deinit(self.gpa);
        self.draw_holder.list.deinit();
        self.id_stack.deinit();
        self.input.deinit();
        self.arena.deinit();
    }

    /// Arena allocator (for cmd text/image payloads). Reset on the next beginFrame.
    /// When `track_frame_arena` is set, the returned allocator records alloc count and
    /// peak outstanding bytes for the tooltip bench. Production leaves the flag off.
    pub fn allocator(self: *Context) Allocator {
        if (self.track_frame_arena) {
            return .{ .ptr = self, .vtable = &frame_arena_vtable };
        }
        return self.arena.allocator();
    }

    /// Enable or disable the layout sanity scan for subsequent frames.
    pub fn setLayoutSanityEnabled(self: *Context, enabled: bool) void {
        self.layout_sanity_enabled = enabled;
        self.layout_sanity_result = .{ .enabled = enabled };
    }

    /// Copy `pixels` onto the frame arena. Valid until the next beginFrame.
    /// Use this when a tooltip builder generates a thumbnail that must outlive the call.
    pub fn dupePixels(self: *Context, pixels: []const u32) []u32 {
        return self.allocator().dupe(u32, pixels) catch @panic("dupePixels: OOM");
    }

    /// Access the frame's main draw list while the widget tree is being built.
    /// The returned pointer is borrowed until the next phase transition; retaining it and using
    /// it in a later phase violates the Context lifecycle contract.
    pub fn mainDrawList(self: *Context) *DrawList {
        return self.drawListFor(.main, "mainDrawList");
    }

    /// Access the draw list after a frame, or before the first frame for inspection setup.
    /// The returned pointer is borrowed until the next beginFrame; retaining it and using it
    /// during main or display-only build violates the Context lifecycle contract.
    pub fn postFrameDrawList(self: *Context) *DrawList {
        return self.drawListFor(.post_frame, "postFrameDrawList");
    }

    fn drawListFor(self: *Context, access: DrawAccess, accessor: []const u8) *DrawList {
        const phase = self.draw_holder.phase;
        if (self.layer_scope_depth != 0) {
            std.debug.panic("gui: {s} is not available in a layer scope", .{accessor});
        }
        if (!drawAccessAllowed(phase, access)) {
            std.debug.panic("gui: {s} is not available in phase {s}", .{ accessor, @tagName(phase) });
        }
        return &self.draw_holder.list;
    }

    /// Start a filled path. Verbs and points go on the frame arena; `finish`
    /// appends one DrawCmd on success and nothing on InvalidPath or OOM.
    pub fn beginPath(self: *Context) draw.PathBuilder {
        return self.mainDrawList().beginPath(self.allocator());
    }

    /// screen_w/screen_h are logical size (DrawList root clip / layout root).
    /// Not physical framebuffer dimensions. scale is applied in gui.render(..., scale).
    pub fn beginFrame(self: *Context, screen_w: u32, screen_h: u32) void {
        const frame_time = @as(f64, @floatFromInt(self.frame_index)) / 60.0;
        self.frame_index += 1;
        self.beginFrameAtInternal(screen_w, screen_h, frame_time);
    }

    /// Start a frame with an explicit wall-clock or harness virtual time.
    /// screen_w/screen_h are logical size (same contract as beginFrame).
    pub fn beginFrameAt(self: *Context, screen_w: u32, screen_h: u32, now_s: f64) void {
        self.beginFrameAtInternal(screen_w, screen_h, now_s);
    }

    fn beginFrameAtInternal(self: *Context, screen_w: u32, screen_h: u32, now_s: f64) void {
        self.requireNoFrame("beginFrame");
        self.draw_holder.phase = .main_build;
        self.draw_holder.display_only_depth = 0;
        self.screen_w = screen_w;
        self.screen_h = screen_h;
        self.now_s = now_s;
        _ = self.arena.reset(.retain_capacity); // Release the previous frame's payload and layout tree here
        // The layer records point into the arena that was just released. The slots do not:
        // they are what carries a layer's geometry across the reset.
        self.layers_len = 0;
        self.command_targets_len = 0;
        self.input.beginFrame();
        self.id_stack.clear();
        self.state.beginFrame();
        self.per_id_state.beginFrame();
        self.animation_seen_hover = 0;
        self.animation_seen_press = 0;
        self.composition = .{};
        self.focus_order.clearRetainingCapacity();
        self.focus_scope_order.clearRetainingCapacity();
        self.text_input_ids.clearRetainingCapacity();
        self.focus_move = .none;
        self.wheel_remaining = .{};
        self.wheel_remaining_seeded = false;
        {
            const tmp = self.scroll_areas_prev;
            self.scroll_areas_prev = self.scroll_areas_cur;
            self.scroll_areas_cur = tmp;
            self.scroll_areas_cur.clearRetainingCapacity();
            const layer_tmp = self.scroll_area_layers_prev;
            self.scroll_area_layers_prev = self.scroll_area_layers_cur;
            self.scroll_area_layers_cur = layer_tmp;
            self.scroll_area_layers_cur.clearRetainingCapacity();
        }
        self.wheel_chain_ready = false;
        self.wheel_chain_head = 0;
        self.wheel_chain_mouse = .{ .x = 0, .y = 0 };
        // tooltip frame-local (continuous-hover id/start/rect persist across frames)
        self.tooltip_last_id = 0;
        self.tooltip_last_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        self.tooltip_last_hovered = false;
        self.tooltip_hover_refreshed = false;
        self.tooltip_candidate = null;
        self.tooltip_candidate_anchor = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        self.tooltip_builder_calls = 0;
        self.tooltip_layout_calls = 0;
        self.frame_arena_allocs = 0;
        self.frame_arena_live = 0;
        self.frame_arena_peak = 0;
        self.drag_submitted_this_frame = false;
        // The cells a group collects live on the frame arena, so the group cannot outlive the frame.
        self.slider_group = null;
        self.table = null;
        self.draw_holder.list.reset(screen_w, screen_h);
        // Implicit layout-tree root (callers just start with beginBox)
        const root = self.allocator().create(layout.Node) catch @panic("Context.beginFrame: OOM");
        root.* = .{ .cfg = .{
            .direction = .column,
            .width = .{ .fixed = @intCast(screen_w) },
            .height = .{ .fixed = @intCast(screen_h) },
        } };
        self.layout_root = root;
        self.layout_current = root;
        // Input that arrived before the frame opened. Applied here — after input.beginFrame has
        // cleared the previous frame's edges, before any widget reads input — so that a caller
        // may forward events either side of beginFrame and see the same result.
        if (self.staged_input.drain(&self.input)) |staged| self.composition = staged;
        const previous_route_key = self.layer_route.frontmost_key;
        self.latchLayerRoute();
        self.applyLayerRouteTransition(previous_route_key);
        self.latchLayerTextInputGate();
        self.current_layer_scope = self.mainLayerScope();
        self.layer_scope_depth = 0;
    }

    /// Fail on a broken lifecycle contract, in every optimisation mode.
    ///
    /// These are not internal consistency checks a release build can afford to drop. A Context
    /// driven out of phase — widgets built with no frame open, a box left unclosed, a post-frame
    /// API called mid-frame — cannot produce a meaningful frame, and carrying on yields a wrong
    /// interface rather than a slow one. `std.debug.assert` compiles to `unreachable`, which is
    /// removed under `ReleaseFast` and `ReleaseSmall`, so the checks below panic explicitly.
    ///
    /// Only the failure handling is shared here. The predicates stay where they can be read: the
    /// phase ones in `requireFrame`/`requireNoFrame`, the state ones at the call site.
    ///
    /// Runs while widgets are built — proportional to the number of widgets, never to pixels or
    /// samples. One bool test on the success path, `noreturn` on the failure path.
    pub inline fn requireContract(ok: bool, comptime what: []const u8) void {
        if (!ok) @panic("gui: " ++ what);
    }

    /// Require a frame-build phase: `beginFrame` has run and the Context is still accepting
    /// frame-build calls. This fails from custom draw callbacks, because emit phases are not a
    /// frame-build phase.
    pub inline fn requireFrame(self: *const Context, comptime what: []const u8) void {
        requireContract(self.frameIsOpen(), what ++ " requires an open frame");
    }

    /// Require an idle or final-overlay phase. This is used by lifecycle APIs that are meaningful
    /// only between frames. It also fails during the synchronous layout/emit work of `endFrame`,
    /// even though `endFrame` has not returned yet.
    pub inline fn requireNoFrame(self: *const Context, comptime what: []const u8) void {
        requireContract(self.noFrameIsOpen(), what ++ " must be called with no frame open");
    }

    /// Require that a display-only tooltip builder is not running.
    ///
    /// Interactive widgets, focus / scroll / popup / drag mutation, per-id store
    /// touches, nested tooltips, and input injection are lifecycle violations
    /// inside a display-only tooltip subtree, which does not arbitrate against what is under it.
    /// Checked at each public API entry, before
    /// any caller-owned write, so a first-frame (empty rect cache) call still
    /// fails. Panics in every optimisation mode (same class as `requireContract`).
    pub inline fn requireInteractiveAllowed(self: *const Context, comptime what: []const u8) void {
        requireContract(self.draw_holder.display_only_depth == 0, what ++ " is not allowed in a display-only subtree");
    }

    fn frameIsOpen(self: *const Context) bool {
        return switch (self.draw_holder.phase) {
            .main_build, .display_only_build => true,
            .idle, .main_emit, .layer_emit, .final_overlay => false,
        };
    }

    fn noFrameIsOpen(self: *const Context) bool {
        return switch (self.draw_holder.phase) {
            .idle, .final_overlay => true,
            .main_build, .display_only_build, .main_emit, .layer_emit => false,
        };
    }

    fn checkDisplayOnlyInvariant(self: *const Context) void {
        const in_display_only = self.draw_holder.phase == .display_only_build;
        requireContract(in_display_only == (self.draw_holder.display_only_depth > 0), "display-only phase and depth disagree");
    }

    pub fn endFrame(self: *Context) void {
        self.requireFrame("endFrame");
        // Every beginDisabled needs a matching endDisabled within the same frame (immediate-mode
        // begin/end nesting rule, the same contract beginCollapsible's body depth follows).
        requireContract(self.disabled_depth == 0, "endFrame with a beginDisabled scope still open");
        // Likewise every beginSliderGroup needs its endSliderGroup: the group's column widths are
        // written back there, so an unclosed group would leave its rows at zero-width columns.
        requireContract(self.slider_group == null, "endFrame with a slider group still open");
        requireContract(self.table == null, "endFrame with a table still open");
        requireContract(self.draw_holder.display_only_depth == 0, "endFrame with a display-only subtree still open");
        self.checkDisplayOnlyInvariant();
        const root = self.layout_root.?;
        // Detect beginBox / endBox mismatches
        requireContract(self.layout_current == root, "endFrame with a box still open");
        requireContract(self.layer_scope_depth == 0, "endFrame with a layer scope still open");
        // Frames that never use the layout API (empty root) skip layout / emit / cache update
        // entirely: compatible with manual DrawList use (examples 08/09). rect_cache keeps the previous values.
        const screen_rect = Rect{ .x = 0, .y = 0, .w = self.screen_w, .h = self.screen_h };
        // The tooltip is a layer like any other; registering it here rather than at the
        // `tooltip` / `tooltipBox` call is what keeps a candidate that was replaced during the
        // frame from leaving a record behind.
        self.registerTooltipLayer();
        const has_main = root.first_child != null;
        // Frames that never use the layout API (empty root, no layer) skip layout / emit /
        // cache update entirely: compatible with manual DrawList use (examples 08/09).
        // rect_cache keeps the previous values.
        if (has_main or self.layers_len > 0) {
            if (has_main) layout.layoutTree(root, screen_rect, self.font, self.allocator());
            self.rect_cache.clearRetainingCapacity();
            // From here until the layers are placed, the cache holds this frame's main rects.
            // That is what an `.id` anchor reads, and it is why no second table of current
            // geometry is needed. `endFrame` is synchronous, so nothing outside observes the
            // half-updated state in between.
            if (has_main) self.updateRectCache(root, screen_rect);
            self.placeLayers(screen_rect);
            self.draw_holder.phase = .main_emit;
            if (has_main) self.emitNode(root, &self.draw_holder.list);
            self.draw_holder.phase = .layer_emit;
            self.emitLayers();
        }
        if (self.layout_sanity_enabled) {
            self.layout_sanity_result = layout_sanity_probe.scan(root, self.font, self.allocator());
            // Each placed layer is a root of its own, scanned separately and summed in. A
            // marker is not in the main tree by the time the probe runs, so nothing is
            // counted twice; a layer that was not placed is not on screen to be counted.
            var i: usize = 0;
            while (i < self.layers_len) : (i += 1) {
                if (self.layers[i].status != .placed) continue;
                const r = layout_sanity_probe.scan(self.layers[i].root, self.font, self.allocator());
                self.layout_sanity_result.text_overflow += r.text_overflow;
                self.layout_sanity_result.sibling_overlap += r.sibling_overlap;
                self.layout_sanity_result.content_overflow += r.content_overflow;
            }
        }
        // Seal this frame's viewport rects so the next frame's wheel chain reads
        // previous-frame geometry (same 1-frame lag as hit-test).
        for (self.scroll_areas_cur.items) |*rec| {
            if (self.rect_cache.get(rec.id)) |c| rec.rect = c.rect;
        }
        self.sealScrollAreaRootOrders();
        self.clearMissingLayerFocus();
        if (self.layers_len != 0 or self.layer_slots_len != 0) self.sealLayerSlots();
        // If the target was not refreshed this frame, clear the timer (suppress stale overlays for hidden widgets)
        if (self.tooltip_hover_id != 0 and !self.tooltip_hover_refreshed) {
            self.tooltip_hover_id = 0;
        }
        // Tab moves the focus forward, Shift+Tab back. The event is read but not consumed, so an
        // application that gives Tab its own meaning still sees it.
        if (self.input.pressedPlain(input_mod.key.tab, input_mod.mod.shift, input_mod.mod.ctrl | input_mod.mod.alt | input_mod.mod.cmd)) {
            self.focus_move = .prev;
        } else if (self.input.pressedPlain(input_mod.key.tab, 0, input_mod.mod.all)) {
            self.focus_move = .next;
        }
        // A frame the pointer is taking part in belongs to the pointer, so any Tab in it is dropped.
        if (self.pointerEngaged()) self.focus_move = .none;
        // Clear keyboard focus only when no focused TextInput-like widget claimed an outside click this frame.
        // Frames with no mouse down keep focus.
        if (self.input.mouse_pressed.left and !self.state.focus_claimed_this_frame) {
            self.state.focused_id = 0;
            self.focused_layer_key = null;
            self.state.focus_visible = false;
        }
        // If the active widget was not evaluated this frame (hidden / branched away) and the button is
        // already released, clear active_id to prevent stickiness (wantsMouse drag-along).
        if (self.state.active_id != 0 and !self.state.active_submitted and !self.input.mouse_buttons.left) {
            self.state.active_id = 0;
        }
        // An armed (pre-threshold) drag whose source widget was not called this frame is
        // cancelled outright, regardless of button state: `armed` alone never mutates caller
        // state (see dnd.zig), so there is nothing to hand back. A `dragging` drag is exempt —
        // by design it no longer depends on its source widget being resubmitted at all.
        if (self.drag) |d| {
            if (d.phase == .armed and !self.drag_submitted_this_frame) {
                if (self.state.active_id == d.source_id) self.state.active_id = 0;
                self.drag = null;
            }
        }
        // Tab traversal, after the draw commands are out (so the move shows next frame) and before
        // the trim below (so the widget just focused is protected from it).
        self.resolveFocusMove();
        // The focus is settled now — an outside click has cleared it and Tab has moved it — so this
        // is the first point at which "is the focus on a text field?" has a final answer.
        self.focused_text_input_id = 0;
        self.focused_text_input_layer_key = null;
        for (self.text_input_ids.items) |id| {
            if (id == self.state.focused_id) {
                self.focused_text_input_id = id;
                self.focused_text_input_layer_key = self.focusOwnerForId(id);
                break;
            }
        }
        // A wake ID is only retained while its widget is submitted in the current tree.
        if (self.animation_wake_hover != 0 and self.animation_seen_hover != self.animation_wake_hover) {
            self.animation_wake_hover = 0;
        }
        if (self.animation_wake_press != 0 and self.animation_seen_press != self.animation_wake_press) {
            self.animation_wake_press = 0;
        }
        // PerIdStateStore LRU trim. Frame boundary only. Protects visible and in-use IDs.
        self.per_id_state.trim(.{
            .active_id = self.state.active_id,
            .focused_id = self.state.focused_id,
            .hot_id = self.state.hot_id,
            .next_hot_id = self.state.next_hot_id,
            .animation_hover_id = self.animation_wake_hover,
            .animation_press_id = self.animation_wake_press,
        });
        // Neither the arena nor the draw list is reset here (Context is the contract guardian).
        self.draw_holder.phase = .final_overlay;
        self.checkDisplayOnlyInvariant();
    }

    /// Hand one input event to the GUI. Callable at any point in the loop: inside a frame it
    /// applies at once, outside one it is staged and applied by the next beginFrame, in arrival
    /// order (see `StagedInput` in input.zig). Note that staged input reaches `ctx.input` only
    /// when that frame opens, so reading `ctx.input` before beginFrame does not see it yet.
    pub fn pushEvent(self: *Context, ev: InputEvent) void {
        self.requireInteractiveAllowed("pushEvent");
        if (self.frameIsOpen()) {
            self.input.pushEvent(ev);
        } else {
            self.staged_input.pushEvent(ev);
        }
    }

    /// Set IME composition state. Inside a frame `text` is a borrowed slice owned by the caller
    /// (valid through endFrame drawing); outside one the bytes are copied into the staging buffer
    /// and applied by the next beginFrame, so the caller keeps no obligation past the call.
    /// Does not accept platform types (ADR-007).
    pub fn setComposition(self: *Context, state: input_mod.CompositionState) void {
        self.requireInteractiveAllowed("setComposition");
        if (self.frameIsOpen()) {
            self.composition = state;
        } else {
            self.staged_input.setComposition(state);
        }
    }

    /// A previous-frame placed modal layer owns the generic route, so its contribution is
    /// latched before the current tree is built.
    pub fn wantsMouse(self: *const Context) bool {
        return self.layer_route.frontmost_key != null or self.state.active_id != 0 or self.state.this_frame_hovered_any;
    }

    pub fn wantsKeyboard(self: *const Context) bool {
        return self.layer_route.frontmost_key != null or self.state.focused_id != 0;
    }

    /// Whether the keyboard focus is on a text field, which is the value a native IME is switched
    /// on and off with (`Window.setTextInputActive`).
    ///
    /// **This is not `wantsKeyboard`.** That one is true for any focusable — a button, a checkbox,
    /// a slider — because keyboard focus is not specific to text. Driving an IME from it turns
    /// the input method on while the user is tabbing through buttons.
    ///
    /// Read it **after `endFrame` and before the next `pollEvents`**: the focus settles inside
    /// `endFrame`, so during a frame this still reports what the previous one finished with. It
    /// answers yes or no and does not name the field — `focusedId()` is what tells several fields
    /// apart.
    pub fn wantsTextInput(self: *const Context) bool {
        return if (self.layer_route.frontmost_key != null)
            self.latched_layer_text_input
        else
            self.focused_text_input_id != 0;
    }

    /// Enter a disabled scope: every ordinary widget built before the matching `endDisabled`
    /// rejects pointer and keyboard input and draws with `Style.disabledColor`. Nestable (a
    /// disabled section inside an already-disabled one stays disabled through the inner
    /// `endDisabled`). Popup/menu items keep their own, unrelated `enabled` field — this scope is
    /// for ordinary widgets outside a popup (see popup.zig).
    pub fn beginDisabled(self: *Context) void {
        self.requireFrame("beginDisabled");
        self.requireInteractiveAllowed("beginDisabled");
        self.disabled_depth += 1;
    }

    /// Leave a disabled scope opened by `beginDisabled`.
    pub fn endDisabled(self: *Context) void {
        self.requireFrame("endDisabled");
        self.requireInteractiveAllowed("endDisabled");
        requireContract(self.disabled_depth > 0, "endDisabled without a matching beginDisabled");
        self.disabled_depth -= 1;
    }

    /// Whether a widget built right now is inside a `beginDisabled`/`endDisabled` scope.
    pub fn isDisabled(self: *const Context) bool {
        return self.disabled_depth > 0;
    }

    /// If `id` currently holds the focus, hover, or press lock, release it immediately (called
    /// when a widget is submitted disabled). A disabled widget cannot act on Space/Enter or a
    /// drag in progress, so leaving any of these pointed at it would be a ghost: a focus ring
    /// with nothing to activate, a hover tint with nothing to press, an active lock a release
    /// could never resolve. Called at submit time, before this frame's `emitNode` draws the
    /// ring, so disabling a focused widget never draws a stray ring in the same frame.
    ///
    /// Public so every compound widget that hand-assembles its own hit-test instead of routing
    /// through the standard cache-based helper (stepgrid, Listbox row) can release stale state
    /// the same way the standard helper does, not by reimplementing this.
    pub fn clearDisabledInteraction(self: *Context, id: Id) void {
        self.requireInteractiveAllowed("clearDisabledInteraction");
        if (self.state.focused_id == id) {
            self.state.focused_id = 0;
            self.focused_layer_key = null;
            self.state.focus_visible = false;
        }
        if (self.state.active_id == id) self.state.active_id = 0;
        if (self.state.hot_id == id) self.state.hot_id = 0;
        if (self.state.next_hot_id == id) self.state.next_hot_id = 0;
    }

    /// Claim keyboard focus when a widget sees mouse down. Per-ID selection state
    /// lives in a separate store, so switching focus does not clear the selection.
    ///
    /// The focus this gives is not "focus-visible": no ring is drawn, because the caller already
    /// knows where it put the focus. Only Tab traversal raises the ring.
    pub fn claimFocus(self: *Context, id: Id) bool {
        self.requireFrame("claimFocus");
        self.requireInteractiveAllowed("claimFocus");
        if (id == 0 or !self.current_layer_scope.focus_enabled) return false;
        self.state.focused_id = id;
        self.focused_layer_key = self.current_layer_scope.layer_key;
        self.state.focus_visible = false;
        self.state.focus_claimed_this_frame = true;
        return true;
    }

    /// Clear the current keyboard focus. Actual outside-click clear happens in endFrame when no
    /// widget claimed focus this frame.
    pub fn releaseFocus(self: *Context) void {
        self.requireFrame("releaseFocus");
        self.requireInteractiveAllowed("releaseFocus");
        self.state.focused_id = 0;
        self.focused_layer_key = null;
        self.state.focus_visible = false;
    }

    pub fn focusedId(self: *const Context) Id {
        return self.state.focused_id;
    }

    /// Whether `id` holds a focus that was reached with the keyboard, and so should show a ring.
    /// The ring itself is drawn by endFrame; this is for callers that want to match it.
    pub fn isFocusVisible(self: *const Context, id: Id) bool {
        return id != 0 and self.state.focused_id == id and self.state.focus_visible;
    }

    /// Enter `id` into this frame's Tab traversal, at the point it is submitted. The scope
    /// metadata is retained beside the submission so the resolver can keep main-tree entries for
    /// restoration while selecting only the latched modal scope.
    ///
    /// Widgets call this themselves; an application only calls it for something it draws and
    /// hit-tests by hand. Submitting the widget is what puts it in the order, so a widget behind a
    /// closed branch leaves the order on its own.
    ///
    /// Runs once per focusable widget per frame; the append is amortised free after the first
    /// frame because `focus_order` keeps its capacity.
    pub fn registerFocusable(self: *Context, id: Id) void {
        self.requireFrame("registerFocusable");
        self.requireInteractiveAllowed("registerFocusable");
        if (id == 0) return;
        self.focus_order.append(self.gpa, id) catch @panic("Context.registerFocusable: OOM");
        self.focus_scope_order.append(self.gpa, .{
            .layer_key = self.current_layer_scope.layer_key,
            .enabled = self.current_layer_scope.focus_enabled,
        }) catch @panic("Context.registerFocusable: OOM");
    }

    /// Record that `id`, already registered as focusable, is a text field. Called by `textInputId`
    /// for an enabled field only; a disabled one is not a target for the focus or for an IME.
    ///
    /// Runs once per text field per frame, on the frame-build path. It appends and does not search,
    /// so the cost belongs to the trees that have a text field.
    pub fn registerTextInput(self: *Context, id: Id) void {
        self.requireFrame("registerTextInput");
        self.requireInteractiveAllowed("registerTextInput");
        if (id == 0) return;
        self.text_input_ids.append(self.gpa, id) catch @panic("Context.registerTextInput: OOM");
    }

    /// Whether the pointer is taking part in this frame — pressed now, or still held from an
    /// earlier frame in the middle of a drag.
    ///
    /// Keyboard focus stands down for such a frame: Tab does not move, Space and Enter do not
    /// activate, and arrow keys do not step a slider. A press states plainly what the user means
    /// to operate, and a drag in progress owns the widget it grabbed until it is let go — moving
    /// the focus out from under either one would act on something the user is not looking at.
    pub fn pointerEngaged(self: *const Context) bool {
        return self.input.mouse_pressed.left or self.input.mouse_buttons.left;
    }

    /// Whether `id` can be reached by Tab given the geometry it ended up with this frame.
    /// A widget that was submitted but laid out to nothing, or fully clipped away, is invisible to
    /// the user and so must be invisible to traversal.
    fn focusReachable(self: *const Context, id: Id) bool {
        const cached = self.rect_cache.get(id) orelse return false;
        if (cached.rect.w == 0 or cached.rect.h == 0) return false;
        const visible = Rect.intersect(cached.rect, cached.clip);
        return visible.w > 0 and visible.h > 0;
    }

    /// A layer that was routed from the previous frame can lose its anchor before this frame is
    /// placed. The route still absorbs input for the synchronization frame, but no focus may
    /// survive on a layer that was not placed in the frame being sealed. A later reappearance is
    /// a new focus context; main focus restoration remains owned by applyLayerRouteTransition.
    fn clearMissingLayerFocus(self: *Context) void {
        const focused_layer = self.focused_layer_key orelse return;
        var found = false;
        for (self.layers[0..self.layers_len]) |record| {
            if (!record.key.eql(focused_layer)) continue;
            found = true;
            if (record.status == .placed) return;
            break;
        }
        // An omitted marker is the consumer's close-after-event synchronization frame. Keep its
        // focus until the route is released; only a marker that was submitted but could not be
        // placed loses focus because its anchor no longer describes the visible frame.
        if (!found) return;
        self.state.focused_id = 0;
        self.focused_layer_key = null;
        self.state.focus_visible = false;
    }

    /// Move the focus to the next or previous entry of this frame's traversal order.
    ///
    /// Called from endFrame after the draw commands are emitted, so the move lands on the *next*
    /// frame's drawing — the same generation rule the previous-frame hit-test follows (ADR-016).
    fn resolveFocusMove(self: *Context) void {
        const direction = self.focus_move;
        if (direction == .none) return;
        requireContract(self.focus_order.items.len == self.focus_scope_order.items.len, "focus scope metadata is out of sync");

        // Reachability is decided from the rect cache endFrame has just refreshed, so this reads
        // the geometry of the frame that is ending, not of the one before it.
        var reachable: usize = 0;
        for (self.focus_order.items, 0..) |id, i| {
            if (self.focusEntryAllowed(i) and self.focusReachable(id)) reachable += 1;
        }
        // Nothing to land on. Leaving focus_claimed_this_frame alone matters: raising it here would
        // suppress the outside-click clear for a move that never happened.
        if (reachable == 0) return;

        const current = self.state.focused_id;
        var current_index: ?usize = null;
        for (self.focus_order.items, 0..) |id, i| {
            if (id == current and self.focusEntryAllowed(i) and self.focusReachable(id)) {
                current_index = i;
                break;
            }
        }

        const next_id = if (current_index) |start| blk: {
            // Step over unreachable entries, wrapping at the ends. At most one lap: `reachable` is
            // non-zero, so a reachable entry is always found.
            const len = self.focus_order.items.len;
            var step: usize = 1;
            while (step <= len) : (step += 1) {
                const i = switch (direction) {
                    .next => (start + step) % len,
                    .prev => (start + len - (step % len)) % len,
                    .none => unreachable,
                };
                const id = self.focus_order.items[i];
                if (self.focusEntryAllowed(i) and self.focusReachable(id)) break :blk id;
            }
            break :blk current;
        } else blk: {
            // The focus is gone (or was never in the order): start from whichever end the
            // direction implies.
            switch (direction) {
                .next => for (self.focus_order.items, 0..) |id, i| {
                    if (self.focusEntryAllowed(i) and self.focusReachable(id)) break :blk id;
                },
                .prev => {
                    var i = self.focus_order.items.len;
                    while (i > 0) {
                        i -= 1;
                        const id = self.focus_order.items[i];
                        if (self.focusEntryAllowed(i) and self.focusReachable(id)) break :blk id;
                    }
                },
                .none => unreachable,
            }
            unreachable; // reachable > 0 was checked above
        };

        self.state.focused_id = next_id;
        self.focused_layer_key = null;
        for (self.focus_order.items, 0..) |id, i| {
            if (id == next_id and self.focusEntryAllowed(i) and self.focusReachable(id)) {
                self.focused_layer_key = self.focus_scope_order.items[i].layer_key;
                break;
            }
        }
        self.state.focus_visible = true;
        self.state.focus_claimed_this_frame = true;
    }

    fn focusEntryAllowed(self: *const Context, index: usize) bool {
        const entry = self.focus_scope_order.items[index];
        if (!entry.enabled) return false;
        const frontmost = self.layer_route.frontmost_key orelse return entry.layer_key == null;
        const owner = entry.layer_key orelse return false;
        return owner.eql(frontmost);
    }

    fn focusOwnerForId(self: *const Context, id: Id) ?LayerKey {
        for (self.focus_order.items, 0..) |entry_id, i| {
            if (entry_id == id) return self.focus_scope_order.items[i].layer_key;
        }
        return null;
    }

    pub fn now(self: *const Context) f64 {
        return self.now_s;
    }

    /// Tooltip delay (seconds). Deterministic under beginFrameAt virtual time.
    pub const tooltip_delay_s: f64 = 0.5;

    /// Record the last interactive widget (called additively from behaviorFromCache).
    /// Even without a rect cache yet, record hovered=false so tooltip() / tooltipBox() can no-op.
    pub fn noteLastInteractive(self: *Context, id: Id, rect: Rect, hovered: bool) void {
        self.requireFrame("noteLastInteractive");
        self.requireInteractiveAllowed("noteLastInteractive");
        self.tooltip_last_id = id;
        self.tooltip_last_rect = rect;
        self.tooltip_last_hovered = hovered;
    }

    /// Attach a text tooltip to the interactive widget just evaluated.
    /// No-op if not hovered this frame. When the same id+rect has been continuous for >= `tooltip_delay_s`,
    /// raise an overlay candidate at the end of endFrame. text is duped onto the frame arena.
    /// Same-frame last writer wins against `tooltipBox`.
    pub fn tooltip(self: *Context, tip: []const u8) void {
        self.requireFrame("tooltip");
        self.requireInteractiveAllowed("tooltip");
        if (!self.refreshTooltipHover()) return;
        const dup = self.allocator().dupe(u8, tip) catch @panic("tooltip: OOM");
        self.tooltip_candidate = .{ .text = dup };
    }

    /// Attach a custom-content tooltip to the interactive widget just evaluated.
    /// Hover delay and continuity share `tooltip_hover_*` with `tooltip`.
    ///
    /// Hot path: hover bookkeeping every frame. The builder and measure/place run
    /// once per showing frame (the frame arena is reset every beginFrame, so the
    /// subtree is not cached). They do not run while hidden or before the delay.
    /// Command append only; no per-pixel loop; not RT.
    ///
    /// The builder is display-only: layout and draw-command APIs are allowed;
    /// interactive / state-mutating APIs panic in every optimisation mode.
    /// Tables are forbidden here: they keep a Context-owned state stack and
    /// interactive rows write hover / tooltip state, so allowing one would need
    /// a full save/restore plus a second interactive-row ban — not worth a
    /// table inside a tooltip. Collapsible begin/end are forbidden as a pair
    /// (one side alone would unbalance `collapsibleBodyDepth`).
    /// The subtree is not entered into `rect_cache` or `focus_order`.
    /// Tooltip content does not scroll. If the subtree is larger than the screen,
    /// the root is clipped to the screen (no flip; overflow is cut).
    ///
    /// Image pixels passed to `imageBox` must stay valid through `gui.render`
    /// after `endFrame`. Use application-owned memory or a frame-arena copy
    /// (`dupePixels` / `allocator().dupe`). A caller-stack temporary is not valid.
    /// Same-frame last writer wins against `tooltip`.
    pub fn tooltipBox(self: *Context, build_fn: TooltipBuildFn, build_ctx: *anyopaque) void {
        self.requireFrame("tooltipBox");
        self.requireInteractiveAllowed("tooltipBox");
        if (!self.refreshTooltipHover()) return;
        const root = self.buildTooltipSubtree(build_fn, build_ctx);
        self.tooltip_builder_calls += 1;
        self.tooltip_candidate = .{ .custom = root };
    }

    /// Shared hover-delay bookkeeping for `tooltip` and `tooltipBox`.
    /// Returns true when a candidate should be published this frame.
    fn refreshTooltipHover(self: *Context) bool {
        if (!self.tooltip_last_hovered or self.tooltip_last_id == 0) return false;

        const id = self.tooltip_last_id;
        const rect = self.tooltip_last_rect;
        if (id != self.tooltip_hover_id or !tooltipRectEq(rect, self.tooltip_hover_rect)) {
            self.tooltip_hover_id = id;
            self.tooltip_hover_rect = rect;
            self.tooltip_hover_start_s = self.now();
        }
        self.tooltip_hover_refreshed = true;

        if (self.now() - self.tooltip_hover_start_s < tooltip_delay_s) return false;
        self.tooltip_candidate_anchor = rect;
        return true;
    }

    fn sliderGroupUnchanged(a: ?SliderGroupState, b: ?SliderGroupState) bool {
        const left = a orelse return b == null;
        const right = b orelse return false;
        return left.column_gap == right.column_gap and
            left.cells == right.cells and
            left.last == right.last and
            left.label_w == right.label_w and
            left.value_w == right.value_w;
    }

    fn tableUnchanged(a: ?table_mod.TableState, b: ?table_mod.TableState) bool {
        const left = a orelse return b == null;
        const right = b orelse return false;
        return left.id == right.id and
            left.cols.ptr == right.cols.ptr and
            left.cols.len == right.cols.len and
            left.header_built == right.header_built and
            left.body_opened == right.body_opened and
            left.row_open == right.row_open and
            left.cell_open == right.cell_open and
            left.row_index == right.row_index;
    }

    /// Build a detached tooltip subtree. `layout_current` is swapped to a frame-arena
    /// root for the builder and restored on the way out. Builder imbalance is a
    /// lifecycle violation (a silent restore would hide an unclosed box).
    fn buildTooltipSubtree(self: *Context, build_fn: TooltipBuildFn, build_ctx: *anyopaque) *layout.Node {
        const pad = self.style.spacing.popup_inset;
        const root = self.allocator().create(layout.Node) catch @panic("tooltipBox: OOM");
        root.* = .{
            .cfg = .{
                .direction = .column,
                .width = .fit,
                .height = .fit,
                .padding = .{ pad, pad, pad, pad },
            },
        };

        const saved_layout = self.layout_current;
        const saved_disabled = self.disabled_depth;
        const saved_scroll_len = self.scroll_stack.items.len;
        const saved_slider = self.slider_group;
        const saved_table = self.table;
        const saved_collapsible = widgets.collapsibleBodyDepth();
        const saved_id_len = self.id_stack.stack.items.len;
        const saved_ids = self.allocator().dupe(Id, self.id_stack.stack.items) catch @panic("tooltipBox: OOM");
        const saved_phase = self.draw_holder.phase;
        const saved_display = self.draw_holder.display_only_depth;

        self.layout_current = root;
        requireContract(saved_phase == .main_build, "tooltipBox builder started in an unexpected draw phase");
        self.draw_holder.display_only_depth += 1;
        self.draw_holder.phase = .display_only_build;
        self.checkDisplayOnlyInvariant();
        defer {
            self.layout_current = saved_layout;
            self.draw_holder.display_only_depth = saved_display;
            self.draw_holder.phase = saved_phase;
            self.checkDisplayOnlyInvariant();
        }

        build_fn(build_ctx, self);

        requireContract(self.layout_current == root, "tooltipBox builder left a box open");
        requireContract(self.disabled_depth == saved_disabled, "tooltipBox builder changed disabled depth");
        requireContract(self.scroll_stack.items.len == saved_scroll_len, "tooltipBox builder changed scroll stack");
        requireContract(sliderGroupUnchanged(self.slider_group, saved_slider), "tooltipBox builder changed slider group");
        requireContract(tableUnchanged(self.table, saved_table), "tooltipBox builder changed table");
        requireContract(widgets.collapsibleBodyDepth() == saved_collapsible, "tooltipBox builder changed collapsible depth");
        requireContract(self.draw_holder.display_only_depth == saved_display + 1, "tooltipBox builder changed display-only depth");
        requireContract(self.id_stack.stack.items.len == saved_id_len, "tooltipBox builder left the id stack unbalanced");
        requireContract(std.mem.eql(Id, self.id_stack.stack.items, saved_ids), "tooltipBox builder changed id stack contents");
        return root;
    }

    pub fn perIdState(self: *Context, id: Id) *state_mod.PerIdState {
        self.requireInteractiveAllowed("perIdState");
        std.debug.assert(id != 0);
        return self.per_id_state.getOrPut(self.gpa, id);
    }

    pub const ButtonColors = struct {
        bg: Color,
        border: Color,
        text: Color,
    };

    /// Resolve button-like colors while preserving the immediate-mode interaction contract.
    /// Feature-off and inactive paths do not touch the per-ID store.
    pub fn resolveButtonColors(
        self: *Context,
        id: Id,
        base_bg: Color,
        selected: bool,
        held: bool,
        disabled: bool,
    ) ButtonColors {
        return self.resolveButtonColorsWithStyle(id, base_bg, selected, held, disabled, null);
    }

    /// Resolve effective widget colors after applying an optional local override.
    /// The animation endpoints are the effective colors, so an override cannot bypass a tween.
    pub fn resolveButtonColorsWithStyle(
        self: *Context,
        id: Id,
        base_bg: Color,
        selected: bool,
        held: bool,
        disabled: bool,
        overrides: ?WidgetStyle,
    ) ButtonColors {
        const style = self.style;
        const hot = self.state.hot_id == id;
        const widget = overrides orelse WidgetStyle{};
        const normal_bg = if (selected)
            widget.selected orelse widget.background orelse base_bg
        else
            widget.background orelse base_bg;
        const hover_bg = widget.hover orelse style.surface.control_hover;
        const active_bg = widget.active orelse style.accent.primary;
        const normal_border = widget.border orelse style.border_tokens.normal;
        const hover_border = widget.hover_border orelse style.border_tokens.hover;
        const text_color = widget.text orelse style.text_tokens.primary;
        if (disabled) {
            return .{
                .bg = style.disabledColor(normal_bg),
                .border = style.disabledColor(normal_border),
                .text = style.disabledColor(text_color),
            };
        }

        const immediate_bg = if (held)
            active_bg
        else if (hot)
            hover_bg
        else
            normal_bg;
        const immediate_border = if (hot or selected) hover_border else normal_border;
        if (!style.animation.enabled) return .{ .bg = immediate_bg, .border = immediate_border, .text = text_color };

        const hover_woken = self.animation_wake_hover == id;
        const press_woken = self.animation_wake_press == id;
        const hover_needed = hot or hover_woken;
        const press_needed = held or press_woken;
        if (!hover_needed and !press_needed) return .{ .bg = immediate_bg, .border = immediate_border, .text = text_color };

        if (hot) self.animation_wake_hover = id;
        if (held) self.animation_wake_press = id;
        if (hover_needed) self.animation_seen_hover = id;
        if (press_needed) self.animation_seen_press = id;

        const per_id = self.perIdState(id);
        const animation = per_id.animationState();
        const hover_amount = if (hover_needed)
            animation.hover.update(if (hot) 1.0 else 0.0, self.now(), style.animation.hover_tau_s)
        else
            0.0;
        const press_amount = if (press_needed)
            animation.press.update(if (held) 1.0 else 0.0, self.now(), style.animation.press_tau_s)
        else
            0.0;

        if (hover_needed) {
            if (hot or !animation.hover.isSettled()) {
                self.animation_wake_hover = id;
            } else {
                if (self.animation_wake_hover == id) self.animation_wake_hover = 0;
            }
        }
        if (press_needed) {
            if (held or !animation.press.isSettled()) {
                self.animation_wake_press = id;
            } else {
                if (self.animation_wake_press == id) self.animation_wake_press = 0;
            }
        }

        var bg = animation_mod.mixColor(normal_bg, hover_bg, hover_amount);
        bg = animation_mod.mixColor(bg, active_bg, press_amount);
        const border = if (selected)
            hover_border
        else
            animation_mod.mixColor(normal_border, hover_border, hover_amount);
        return .{ .bg = bg, .border = border, .text = text_color };
    }

    fn tooltipRectEq(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }

    fn sameLayerKey(a: ?LayerKey, b: ?LayerKey) bool {
        if (a) |left| {
            if (b) |right| return left.eql(right);
            return false;
        }
        return b == null;
    }

    /// Runs once per frame over the retained layer slots, never over the current tree. It fixes
    /// the input owner before the current frame's marker submission can affect it.
    fn latchLayerRoute(self: *Context) void {
        self.layer_route = .{};
        self.dismissed_layer_key = null;
        if (self.layer_slots_len == 0) return;

        var frontmost_index: ?usize = null;
        var i: usize = 0;
        while (i < self.layer_slots_len) : (i += 1) {
            const slot = self.layer_slots[i];
            if (!slot.was_placed or slot.input != .modal) continue;
            if (frontmost_index) |frontmost| {
                if (!layerSlotIsFrontmost(slot, self.layer_slots[frontmost])) continue;
            }
            frontmost_index = i;
            self.layer_route.frontmost_key = slot.key;
        }

        const frontmost = frontmost_index orelse return;
        const slot = self.layer_slots[frontmost];
        const any_mouse_press = self.input.mouse_pressed.left or
            self.input.mouse_pressed.right or self.input.mouse_pressed.middle;
        if (slot.dismiss_on_outside and any_mouse_press) {
            const screen = Rect{ .x = 0, .y = 0, .w = self.screen_w, .h = self.screen_h };
            if (!pointHitsVisible(slot.prev_root_rect, screen, self.input.mouse_pressed_pos)) {
                self.dismissed_layer_key = slot.key;
            }
        }
    }

    /// Apply ownership-transition cleanup after the previous-frame route has been selected.
    /// Pointer state never crosses a route boundary; main focus is restored only after a modal
    /// route has gone away, using the focus that was saved when the route first appeared.
    fn applyLayerRouteTransition(self: *Context, previous: ?LayerKey) void {
        const current = self.layer_route.frontmost_key;
        if (sameLayerKey(previous, current)) return;

        self.state.active_id = 0;
        self.state.hot_id = 0;
        self.state.next_hot_id = 0;
        self.drag = null;

        if (previous == null and current != null) {
            self.saved_main_focus_id = if (self.focused_layer_key == null) self.state.focused_id else 0;
            self.saved_main_text_input_id = if (self.focused_text_input_layer_key == null)
                self.focused_text_input_id
            else
                0;
            self.state.focus_visible = false;
        } else if (previous != null and current == null) {
            if (self.saved_main_focus_id != 0) {
                self.state.focused_id = self.saved_main_focus_id;
                self.focused_layer_key = null;
                self.state.focus_visible = false;
            } else if (self.focused_layer_key != null) {
                self.state.focused_id = 0;
                self.focused_layer_key = null;
                self.state.focus_visible = false;
            }
            self.focused_text_input_id = self.saved_main_text_input_id;
            self.focused_text_input_layer_key = null;
            self.saved_main_focus_id = 0;
            self.saved_main_text_input_id = 0;
        } else if (current != null) {
            if (self.focused_layer_key) |focused_layer| {
                if (!focused_layer.eql(current.?)) {
                    self.state.focused_id = 0;
                    self.focused_layer_key = null;
                    self.state.focus_visible = false;
                }
            }
        }
    }

    fn latchLayerTextInputGate(self: *Context) void {
        self.latched_layer_text_input = if (self.layer_route.frontmost_key) |frontmost| blk: {
            break :blk if (self.focused_text_input_layer_key) |owner|
                owner.eql(frontmost) and self.focused_text_input_id != 0
            else
                false;
        } else self.focused_text_input_layer_key == null and self.focused_text_input_id != 0;
    }

    fn mainLayerScope(self: *const Context) LayerScope {
        const blocked = self.layer_route.frontmost_key != null;
        return .{
            .pointer_enabled = !blocked,
            .keyboard_enabled = !blocked,
            .focus_enabled = !blocked,
            .wheel_enabled = !blocked,
            .previous_geometry_available = true,
            .route_active = !blocked,
            .root_order = 0,
        };
    }

    /// Resolve a marker once at scope entry. Widgets below it then use the copied flags in O(1).
    fn layerScopeFor(self: *const Context, layer_key: LayerKey, input_policy: LayerInputPolicy) LayerScope {
        var i: usize = 0;
        while (i < self.layer_slots_len) : (i += 1) {
            const slot = self.layer_slots[i];
            if (!slot.key.eql(layer_key)) continue;
            const owns_route = input_policy == .modal and slot.was_placed and blk: {
                const frontmost = self.layer_route.frontmost_key orelse break :blk false;
                break :blk slot.key.eql(frontmost);
            };
            return .{
                .layer_key = layer_key,
                .pointer_enabled = owns_route,
                .keyboard_enabled = owns_route,
                .focus_enabled = owns_route,
                .wheel_enabled = owns_route,
                .previous_geometry_available = slot.was_placed,
                .route_active = owns_route,
                .root_order = slot.root_order,
            };
        }
        return .{
            .layer_key = layer_key,
            .pointer_enabled = false,
            .keyboard_enabled = false,
            .focus_enabled = false,
            .wheel_enabled = false,
            .previous_geometry_available = false,
            .route_active = false,
            .root_order = 0,
        };
    }

    fn pushLayerScope(self: *Context, layer_key: LayerKey, input_policy: LayerInputPolicy) void {
        requireContract(self.layer_scope_depth < max_layers, "layer scope nesting exceeds the maximum");
        self.layer_scope_stack[self.layer_scope_depth] = self.current_layer_scope;
        self.layer_scope_depth += 1;
        self.current_layer_scope = self.layerScopeFor(layer_key, input_policy);
    }

    fn popLayerScope(self: *Context) void {
        requireContract(self.layer_scope_depth > 0, "layer scope stack underflow");
        self.layer_scope_depth -= 1;
        self.current_layer_scope = self.layer_scope_stack[self.layer_scope_depth];
    }

    // ──────────────────────────────────────────────
    // Layout-tree build API
    // ──────────────────────────────────────────────

    /// Open a box. Must be paired with endBox.
    /// cfg.id == 0 → auto-assigned (not externally referenceable; not registered in the rect cache).
    /// Passing an explicit ID (non-zero from IdStack etc.) makes it subject to getNodeRect /
    /// rect_cache (for hit-test) after endFrame.
    pub fn beginBox(self: *Context, cfg: BoxConfig) void {
        self.requireFrame("beginBox");
        layout.assertBoxConfigValid(cfg);
        const parent = self.layout_current.?;
        const node = self.allocator().create(layout.Node) catch @panic("Context.beginBox: OOM");
        node.* = .{
            .id = if (cfg.id != 0) cfg.id else id_mod.hashInt(parent.id, parent.child_count),
            .cfg = cfg,
        };
        if (cfg.layer) |spec_ptr| {
            const spec = spec_ptr.*;
            self.registerLayer(spec, node, parent);
            layout.attachDetached(parent, node);
            self.pushLayerScope(spec.key, spec.input);
        } else {
            layout.appendChild(parent, node);
        }
        self.layout_current = node;
    }

    /// Record a layer for this frame. Called from `beginBox` when the box carries a marker.
    ///
    /// Hot path: every frame, once per layer. O(1), and a frame with no layer never reaches
    /// it — a tree that uses no layer pays one null check per box for the whole feature.
    fn registerLayer(self: *Context, spec: LayerSpec, root: *layout.Node, logical_parent: *layout.Node) void {
        requireContract(spec.cache or spec.input != .modal, "a modal layer must be cache-enabled");
        requireContract(spec.input == .modal or !spec.dismiss_on_outside, "outside dismissal requires a modal layer");
        var i: usize = 0;
        while (i < self.layers_len) : (i += 1) {
            requireContract(
                !self.layers[i].key.eql(spec.key),
                "two layers with the same key in one frame",
            );
        }
        if (self.layers_len >= max_layers) {
            // The count, the cap and where it happened, because a caller who hits this needs
            // to find which registration was the extra one.
            std.debug.print(
                "gui: layer registration overflow: layer {d} of a maximum {d}, key {d}, inside box id {d}\n",
                .{ self.layers_len + 1, max_layers, spec.key.value, logical_parent.id },
            );
            requireContract(false, "more layers in one frame than the maximum");
        }
        self.layers[self.layers_len] = .{
            .key = spec.key,
            .z = spec.z,
            .serial = @intCast(self.layers_len),
            .root_order = 0,
            .root = root,
            .placement = spec.placement,
            .status = .waiting,
            .cache = spec.cache,
            .depends_on = null,
            .input = spec.input,
            .dismiss_on_outside = spec.dismiss_on_outside,
        };
        self.layers_len += 1;
    }

    /// The slot for `key`, created on first use. Slots outlive frames, so this is where a
    /// layer's previous geometry and route metadata come from.
    fn layerSlot(self: *Context, layer_key: LayerKey) *LayerSlot {
        var i: usize = 0;
        while (i < self.layer_slots_len) : (i += 1) {
            if (self.layer_slots[i].key.eql(layer_key)) return &self.layer_slots[i];
        }
        requireContract(self.layer_slots_len < max_layers, "more layer slots than the maximum");
        self.layer_slots[self.layer_slots_len] = .{ .key = layer_key };
        self.layer_slots_len += 1;
        return &self.layer_slots[self.layer_slots_len - 1];
    }

    /// Where this layer was placed on the previous frame, or null if it was not on screen.
    /// The input arbitration built on top of layers reads this; nothing in placement does.
    pub fn layerPrevRect(self: *const Context, layer_key: LayerKey) ?Rect {
        var i: usize = 0;
        while (i < self.layer_slots_len) : (i += 1) {
            const slot = self.layer_slots[i];
            if (slot.key.eql(layer_key)) return if (slot.was_placed) slot.prev_root_rect else null;
        }
        return null;
    }

    /// Whether the previous-frame frontmost modal layer received an outside press this frame.
    /// This is a stable event result; reading it never closes or consumes the layer.
    pub fn layerDismissed(self: *const Context, layer_key: LayerKey) bool {
        return if (self.dismissed_layer_key) |dismissed| dismissed.eql(layer_key) else false;
    }

    /// Register one explicit main-tree control that menuBar may keep clickable while its own
    /// modal layer owns the route. The control is only eligible for pointer input outside that
    /// layer's previous-frame root; it never opens a general escape from modal routing.
    pub fn registerCommandTarget(self: *Context, id: Id, route_key: LayerKey) void {
        self.requireFrame("registerCommandTarget");
        self.requireInteractiveAllowed("registerCommandTarget");
        requireContract(id != 0, "command target requires a non-zero id");
        var i: usize = 0;
        while (i < self.command_targets_len) : (i += 1) {
            requireContract(self.command_targets[i].id != id, "two command targets with the same id in one frame");
        }
        requireContract(self.command_targets_len < self.command_targets.len, "more command targets than the maximum");
        self.command_targets[self.command_targets_len] = .{ .id = id, .route_key = route_key };
        self.command_targets_len += 1;
    }

    fn commandTargetRegistered(self: *const Context, id: Id, route_key: LayerKey) bool {
        for (self.command_targets[0..self.command_targets_len]) |target| {
            if (target.id == id and target.route_key.eql(route_key)) return true;
        }
        return false;
    }

    /// Whether a registered command target may use the pointer at `point`. The named menu must
    /// own the previous-frame route, and the point must be outside that route owner's root.
    /// Visible modal descendants therefore win before this exception is considered.
    fn commandTargetOutsideRoute(self: *const Context, id: Id, route_key: LayerKey, point: Vec2) bool {
        if (!self.commandTargetRegistered(id, route_key)) return false;
        const frontmost = self.layer_route.frontmost_key orelse return false;
        if (!frontmost.eql(route_key)) return false;
        const root = self.layerPrevRect(route_key) orelse return false;
        const screen = Rect{ .x = 0, .y = 0, .w = self.screen_w, .h = self.screen_h };
        return !pointHitsVisible(root, screen, point);
    }

    /// Pointer permission for a command target. Hover and press use their own edge coordinates;
    /// an already active target remains eligible for release even if the pointer later moves.
    fn commandTargetPointerEnabled(
        self: *const Context,
        id: Id,
        route_key: LayerKey,
        rect: Rect,
        clip: Rect,
    ) bool {
        if (self.current_layer_scope.pointer_enabled) return true;
        if (self.state.active_id == id) return true;
        if (self.commandTargetOutsideRoute(id, route_key, self.input.mouse_pos) and
            pointHitsVisible(rect, clip, self.input.mouse_pos)) return true;
        return self.input.mouse_pressed.left and
            self.commandTargetOutsideRoute(id, route_key, self.input.mouse_pressed_pos) and
            pointHitsVisible(rect, clip, self.input.mouse_pressed_pos);
    }

    fn noteCommandTargetPress(self: *Context, route_key: LayerKey) void {
        if (self.dismissed_layer_key) |dismissed| {
            if (dismissed.eql(route_key)) self.dismissed_layer_key = null;
        }
    }

    /// The key the tooltip layer occupies. Reserved rather than derived, because there is
    /// exactly one tooltip at a time and its slot has to be the same one across frames.
    const tooltip_layer_key: LayerKey = .{ .value = 0x0071717 };

    /// Turn this frame's tooltip candidate, if there is one, into a layer.
    ///
    /// Registering here rather than at the `tooltip` / `tooltipBox` call is deliberate: the
    /// last writer of a frame wins, and a candidate that was replaced must not leave a layer
    /// behind. Both kinds become a node tree, so the background and the border are emitted by
    /// the layer in z order rather than drawn beside it.
    fn registerTooltipLayer(self: *Context) void {
        const cand = self.tooltip_candidate orelse return;
        if (self.screen_w == 0 or self.screen_h == 0) return;
        const style = self.style;
        const pad = style.spacing.popup_inset;
        const root: *layout.Node = switch (cand) {
            .custom => |tip_root| blk: {
                self.tooltip_layout_calls += 1;
                break :blk tip_root;
            },
            .text => |tip| blk: {
                const r = self.allocator().create(layout.Node) catch @panic("tooltip: OOM");
                r.* = .{ .cfg = .{
                    .direction = .column,
                    .width = .fit,
                    .height = .fit,
                    .padding = .{ pad, pad, pad, pad },
                } };
                // Match popup items: keep the token as a minimum, but let a larger font's
                // natural ink height expand the row so the text is never clipped.
                const row_height = @max(style.spacing.popup_item_height, font_mod.fontInkHeight(self.font));
                const row = self.allocator().create(layout.Node) catch @panic("tooltip: OOM");
                row.* = .{ .cfg = .{
                    .direction = .row,
                    .width = .fit,
                    .height = .{ .fixed = row_height },
                    .align_cross = .center,
                } };
                const leaf = self.allocator().create(layout.Node) catch @panic("tooltip: OOM");
                leaf.* = .{ .cfg = .{}, .leaf = .{ .text = .{
                    .str = self.allocator().dupe(u8, tip) catch @panic("tooltip: OOM"),
                    .color = style.text_tokens.primary,
                    .font = null,
                } } };
                layout.appendChild(row, leaf);
                layout.appendChild(r, row);
                break :blk r;
            },
        };
        root.cfg.bg = style.surface.control;
        root.cfg.border = .{ .color = style.border_tokens.normal, .thickness = 1 };
        self.registerLayer(.{
            .key = tooltip_layer_key,
            // Above ordinary layers: a tooltip explains what is already on screen, so nothing
            // an application places should cover it.
            .z = 1000,
            .placement = .{
                .source = .{ .point = .{
                    .x = self.tooltip_candidate_anchor.x,
                    .y = self.tooltip_candidate_anchor.y + @as(i32, @intCast(self.tooltip_candidate_anchor.h)) + pad,
                } },
                // A tooltip does not flip: its contract is that overflow is cut, not moved.
                .flip = .none,
                .shift = .both_axes,
            },
            // A tooltip is only ever looked at. Keeping it out of the cache keeps its ids out
            // of the one explicit-id namespace, which is the contract `tooltipBox` already has.
            .cache = false,
        }, root, self.layout_root.?);
    }

    /// Resolve every layer's anchor and lay its root out, in dependency order.
    ///
    /// A layer may anchor into another layer — a submenu against its parent's item — so the
    /// order is the order of the dependency, not of registration. A layer whose anchor is not
    /// in this frame is not placed at all: it would otherwise be drawn at a coordinate from a
    /// frame that no longer describes the screen, which is worse than not drawing it.
    ///
    /// Hot path: every frame, once per layer, and not reached at all on a frame with none.
    fn placeLayers(self: *Context, boundary: Rect) void {
        if (self.layers_len == 0) return;
        self.indexLayerOwners();
        // Each pass places at least one layer, or every remaining layer is blocked and the
        // block is a cycle. Bounding the passes by the count is what turns a cycle into a
        // contract failure rather than a hang.
        var remaining = self.layers_len;
        var pass: usize = 0;
        while (remaining > 0) : (pass += 1) {
            requireContract(pass <= self.layers_len, "a cycle among layer anchors");
            var progressed = false;
            var i: usize = 0;
            while (i < self.layers_len) : (i += 1) {
                const rec = &self.layers[i];
                if (rec.status != .waiting) continue;
                switch (self.resolveAnchor(rec)) {
                    .blocked => continue,
                    .missing => {
                        rec.status = .missing;
                        remaining -= 1;
                        progressed = true;
                    },
                    .ready => |anchor_rect| {
                        popup_mod.layoutLayerRoot(rec.root, boundary, self.font, self.allocator());
                        popup_mod.placeLayerRoot(rec.root, anchor_rect, rec.placement, boundary);
                        if (rec.cache) self.updateRectCache(rec.root, boundary);
                        rec.status = .placed;
                        remaining -= 1;
                        progressed = true;
                    },
                }
            }
            if (!progressed) requireContract(false, "a cycle among layer anchors");
        }
    }

    const AnchorResolve = union(enum) {
        /// The layer it anchors into has not been placed yet.
        blocked,
        /// The anchor is not in this frame.
        missing,
        ready: Rect,
    };

    fn resolveAnchor(self: *Context, rec: *LayerRecord) AnchorResolve {
        switch (rec.placement.source) {
            .point => |p| return .{ .ready = .{ .x = p.x, .y = p.y, .w = 0, .h = 0 } },
            .id => |anchor_id| {
                // Waiting on the layer that owns the anchor is the only thing the owner
                // lookup is for. A missing owner needs no branch of its own: it never wrote
                // its ids into the cache, so the lookup below fails and this layer is missing
                // too — the propagation falls out of the cache rather than being restated.
                if (self.ownerLayerOf(anchor_id)) |owner| {
                    rec.depends_on = owner;
                    if (self.layers[owner].status == .waiting) return .blocked;
                }
                const entry = self.rect_cache.get(anchor_id) orelse return .missing;
                return .{ .ready = entry.rect };
            },
        }
    }

    /// Which layer, if any, owns the box with this explicit id. Only layers that join the
    /// cache can own one, because only their ids are in the namespace at all.
    fn ownerLayerOf(self: *Context, anchor_id: Id) ?usize {
        return self.layer_owner_map.get(anchor_id);
    }

    /// Index cache-visible IDs once for this frame. Layer roots are detached from the main tree
    /// and from one another's child chains, so an inner layer is visited only by its own record;
    /// it cannot be counted as part of its outer layer as well.
    fn indexLayerOwners(self: *Context) void {
        self.layer_owner_map.clearRetainingCapacity();
        for (self.layers[0..self.layers_len], 0..) |record, i| {
            if (!record.cache) continue;
            self.indexLayerOwnerSubtree(record.root, i);
        }
    }

    fn indexLayerOwnerSubtree(self: *Context, node: *const layout.Node, owner: usize) void {
        if (node.cfg.id != 0) {
            const gop = self.layer_owner_map.getOrPut(self.gpa, node.cfg.id) catch
                @panic("Context.placeLayers: OOM");
            requireContract(!gop.found_existing, "two cache-enabled layer boxes have the same explicit id");
            gop.value_ptr.* = owner;
        }
        var it = node.first_child;
        while (it) |child| : (it = child.next_sibling) self.indexLayerOwnerSubtree(child, owner);
    }

    /// Emit the layers over the main tree, nearest the viewer last.
    fn emitLayers(self: *Context) void {
        if (self.layers_len == 0) return;
        // Insertion sort of indices: the count is small and fixed, and keeping it stable is
        // what makes equal `z` fall back to registration order.
        var order: [max_layers]usize = undefined;
        var n: usize = 0;
        for (self.layers[0..self.layers_len], 0..) |rec, i| {
            if (rec.status != .placed) continue;
            var j = n;
            while (j > 0 and layerBefore(self.layers[i], self.layers[order[j - 1]])) : (j -= 1) {
                order[j] = order[j - 1];
            }
            order[j] = i;
            n += 1;
        }
        for (order[0..n], 0..) |i, root_index| {
            self.layers[i].root_order = @intCast(root_index + 1);
            self.emitNode(self.layers[i].root, &self.draw_holder.list);
        }
    }

    /// Give current-frame scroll records the same root order that the layer emitter uses.
    /// The parallel key list keeps LayerKey and z/serial details out of the public record.
    fn sealScrollAreaRootOrders(self: *Context) void {
        requireContract(
            self.scroll_areas_cur.items.len == self.scroll_area_layers_cur.items.len,
            "scroll area scope metadata is out of sync",
        );
        for (self.scroll_areas_cur.items, self.scroll_area_layers_cur.items) |*record, maybe_key| {
            if (maybe_key) |layer_key| {
                record.root_order = self.layerRootOrder(layer_key);
                if (record.root_order == 0) record.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            } else {
                record.root_order = 0;
            }
        }
    }

    fn layerRootOrder(self: *const Context, layer_key: LayerKey) u16 {
        for (self.layers[0..self.layers_len]) |record| {
            if (record.status == .placed and record.input == .modal and record.key.eql(layer_key)) return record.root_order;
        }
        return 0;
    }

    /// Carry placed current markers into the one-frame history and release every absent or
    /// unresolved marker after the frame has been sealed. The compact prefix is the free list.
    fn sealLayerSlots(self: *Context) void {
        var i: usize = 0;
        while (i < self.layer_slots_len) {
            var present = false;
            for (self.layers[0..self.layers_len]) |rec| {
                if (rec.key.eql(self.layer_slots[i].key)) {
                    present = true;
                    break;
                }
            }
            if (!present) {
                self.releaseLayerSlotAt(i);
                continue;
            }
            i += 1;
        }

        var j: usize = 0;
        while (j < self.layers_len) : (j += 1) {
            const rec = self.layers[j];
            if (rec.status != .placed) {
                self.releaseLayerSlot(rec.key);
                continue;
            }
            const slot = self.layerSlot(rec.key);
            slot.* = .{
                .key = rec.key,
                .z = rec.z,
                .serial = rec.serial,
                .root_order = rec.root_order,
                .input = rec.input,
                .dismiss_on_outside = rec.dismiss_on_outside,
                .prev_root_rect = rec.root.rect,
                .was_placed = true,
            };
        }
    }

    /// Whether this layer was on screen on the previous frame. Distinct from `layerPrevRect`
    /// returning null only in that it does not need the rectangle to answer.
    pub fn layerWasPlaced(self: *const Context, layer_key: LayerKey) bool {
        var i: usize = 0;
        while (i < self.layer_slots_len) : (i += 1) {
            if (self.layer_slots[i].key.eql(layer_key)) return self.layer_slots[i].was_placed;
        }
        return false;
    }

    fn releaseLayerSlot(self: *Context, layer_key: LayerKey) void {
        var i: usize = 0;
        while (i < self.layer_slots_len) : (i += 1) {
            if (!self.layer_slots[i].key.eql(layer_key)) continue;
            self.releaseLayerSlotAt(i);
            return;
        }
    }

    fn releaseLayerSlotAt(self: *Context, index: usize) void {
        requireContract(index < self.layer_slots_len, "layer slot index out of bounds");
        self.layer_slots[index] = self.layer_slots[self.layer_slots_len - 1];
        self.layer_slots_len -= 1;
    }

    /// The layout node of the innermost box still open (the last `beginBox` whose `endBox` has not
    /// run), or the frame's root when no box is open.
    ///
    /// For a widget that must revise a box's configuration after building something the
    /// configuration depends on. The slider group equalises its column widths at
    /// `endSliderGroup`; the table writes fit-column widths, stretch-cell heights,
    /// and sticky-header scroll / bar padding the same way. Valid only until the
    /// frame ends, because the node lives on the frame arena.
    pub fn openBox(self: *Context) *layout.Node {
        self.requireFrame("openBox");
        return self.layout_current.?;
    }

    pub fn endBox(self: *Context) void {
        self.requireFrame("endBox");
        const cur = self.layout_current.?;
        requireContract(cur.parent != null, "endBox without a matching beginBox");
        self.layout_current = cur.parent;
        // A marker borrowed its parent link only to close this scope. Clearing it now means
        // no walk from a layer root can reach the tree it was written in, so a later pass
        // cannot pick up the parent's clip, scroll or extent by accident.
        if (cur.is_layer_root) {
            cur.parent = null;
            self.popLayerScope();
        }
    }

    /// text leaf (default color = style.text). str is duped onto the arena, so it does not
    /// depend on the caller buffer's lifetime. Paragraph breaks become multiple lines;
    /// paragraphs themselves are not wrapped (`overflow = .visible`).
    pub fn label(self: *Context, str: []const u8) void {
        self.labelEx(str, self.style.text_tokens.primary);
    }

    pub fn labelEx(self: *Context, str: []const u8, col: Color) void {
        self.requireFrame("labelEx");
        const dup = self.allocator().dupe(u8, str) catch @panic("Context.labelEx: OOM");
        self.addLeaf(.{ .text = .{ .str = dup, .color = col, .font = null } });
    }

    /// Declarative text leaf. `str` is duped onto the frame arena (same ownership as `labelEx`).
    /// `wrap` folds each paragraph at the placed width. `overflow = .ellipsis` with
    /// `max_lines = 0` resolves to one line plus an ellipsis.
    pub fn text(self: *Context, str: []const u8, opts: TextOptions) void {
        self.requireFrame("text");
        const dup = self.allocator().dupe(u8, str) catch @panic("Context.text: OOM");
        const col = opts.color orelse self.style.text_tokens.primary;
        self.addLeaf(.{ .text = .{
            .str = dup,
            .color = col,
            .font = opts.font,
            .wrap = opts.wrap,
            .max_lines = opts.max_lines,
            .overflow = opts.overflow,
        } });
    }

    /// Draw `str` with the color and font of `tier`. Delegates to `text` so
    /// paragraphs and overflow follow that path (no wrap; `overflow = .visible`).
    /// A null tier font uses `Context.font` (the library does not create fonts).
    ///
    /// Hot path: every frame on the GUI widget-build path; field lookup plus the
    /// `text` leaf. Not a per-pixel loop; not RT.
    pub fn labelStyled(self: *Context, str: []const u8, tier: style_mod.TextTier) void {
        const ts = self.style.textStyle(tier);
        const resolved_font = if (ts.font) |explicit| explicit else if (self.default_family) |family|
            family.variant(ts.size, ts.weight) catch @panic("Context.labelStyled: font variant creation failed")
        else
            self.font;
        self.text(str, .{ .color = ts.color, .font = resolved_font });
    }

    /// custom leaf. size is used as the measure result; draw_fn is called with the final rect
    /// after endFrame finalizes layout (DrawList OOM is catch @panic inside the callback).
    pub fn custom(self: *Context, size: Vec2, draw_fn: layout.CustomDrawFn, ctx_ptr: *anyopaque) void {
        self.requireFrame("custom");
        self.addLeaf(.{ .custom = .{ .measured = size, .draw_fn = draw_fn, .ctx = ctx_ptr } });
    }

    /// Final placed rect of an explicit-ID node (registered with cfg.id != 0).
    /// Returns the value settled in the previous endFrame (also unchanged in the first half of the frame right after beginFrame).
    /// The next value becomes available only after this frame's endFrame finishes updateRectCache.
    /// null on the first frame (cache empty), for auto-ID nodes (beginBox cfg.id==0), unknown IDs, or 0.
    pub fn getNodeRect(self: *const Context, id: Id) ?Rect {
        if (id == 0) return null;
        const entry = self.rect_cache.get(id) orelse return null;
        return entry.rect;
    }

    /// Previous-frame {rect, clip, measured} for an explicit-ID widget.
    /// clip is the effective clip after intersecting ancestor clip_children (pass straight to buttonBehavior).
    /// Same previous-frame value as getNodeRect. null on first frame / auto ID / unknown ID / 0.
    pub fn getNodeCachedRect(self: *const Context, id: Id) ?CachedRect {
        if (id == 0) return null;
        return self.rect_cache.get(id);
    }

    /// Seal this frame's wheel chain from previous-frame geometry and the cursor
    /// known at the first `beginScrollArea`. The sealed cursor is stored in
    /// `wheel_chain_mouse` and is the only point `applyScrollAreaWheel` uses, so
    /// a later `pushEvent(mouse_move)` does not reshuffle the chain or retarget
    /// leftover consumption. Callers that push the wheel after `beginFrame`
    /// (the usual loop) are seen here because events apply immediately once the
    /// frame is open.
    ///
    /// An area that was not in the previous-frame registry has no viewport rect
    /// yet, so it is not a wheel target this frame. It becomes one on the next
    /// frame, once `endFrame` has recorded its rect.
    pub fn ensureWheelChain(self: *Context) void {
        // Sealing the chain picks which scroll area the wheel belongs to for the rest of the
        // frame, which is input routing state — not something a display-only tooltip subtree may set.
        self.requireInteractiveAllowed("ensureWheelChain");
        if (self.wheel_chain_ready) return;
        self.wheel_chain_ready = true;
        self.wheel_chain_mouse = self.input.mouse_pos;
        self.wheel_chain_head = pickWheelChainHead(self.scroll_areas_prev.items, self.wheel_chain_mouse);
    }

    /// Previous-frame measured size of an explicit-ID node (natural size from layout.measure).
    /// ScrollArea prefers declared fixed, then recorded content extent, then this value
    /// (`CachedRect.scrollContentSize`). Same previous-frame sync contract as getNodeRect.
    /// null on first frame / auto ID / unknown ID / 0.
    pub fn getNodeMeasured(self: *const Context, id: Id) ?Vec2 {
        if (id == 0) return null;
        const entry = self.rect_cache.get(id) orelse return null;
        return .{ .x = entry.measured_w, .y = entry.measured_h };
    }

    fn addLeaf(self: *Context, leaf: layout.LeafKind) void {
        const parent = self.layout_current.?;
        const node = self.allocator().create(layout.Node) catch @panic("Context.addLeaf: OOM");
        // Wrap / clip / ellipsis need a definite width, so the leaf grows on the
        // width axis. A fit-width ancestor still sees the leaf's intrinsic
        // measure (leaves ignore Sizing at measure time) and expands to
        // max-content — wrap then sees that intrinsic width and does not fold.
        const need_definite_w = switch (leaf) {
            .text => |t| t.wrap or t.overflow != .visible,
            .custom => false,
        };
        node.* = .{
            .id = id_mod.hashInt(parent.id, parent.child_count),
            .cfg = .{ .width = if (need_definite_w) .{ .grow = 1 } else .fit },
            .leaf = leaf,
        };
        layout.appendChild(parent, node);
    }

    /// Register {rect, clip, measured} for an explicit-ID node (pre-order DFS).
    /// Called only after endFrame's measure/place; not used for hit-test during this frame's widget calls.
    ///
    /// `clip` arg = ancestor-derived effective clip (used for this node's draw and hit-test).
    /// Clip passed to children:
    ///   - `clip_children=true`  → `intersect(clip, contentBox(node.rect, padding))`
    ///     (padding sits outside the visible child region; a zero content box empties the clip)
    ///   - `clip_children=false` → `clip` unchanged (overflow draw/hit allowed; even with a zero-size parent,
    ///     children can hit if inside the ancestor clip)
    /// Same definition as `emitNode`'s pushClip bounds (cached clip ↔ draw clip correspondence).
    /// measured_w/h are layout.measure results. content_w/h are the recorded
    /// content extent (-1 if unrecorded). declared_w/h are the clamped `.fixed`
    /// size (-1 if the axis is not `.fixed`). ScrollArea reads them in that
    /// declared → extent → measured order.
    /// Duplicate explicit IDs in the same frame are a contract violation in every build mode.
    fn updateRectCache(self: *Context, node: *const layout.Node, clip: Rect) void {
        if (node.cfg.id != 0) {
            const gop = self.rect_cache.getOrPut(self.gpa, node.cfg.id) catch
                @panic("Context.endFrame: OOM");
            // One namespace covers the main tree and every caching layer, so a duplicate is a
            // contract violation in every build mode rather than a debug-only check: under
            // last-wins, the loser's rect silently becomes the winner's, and hit-testing and
            // anchoring both follow it to the wrong box.
            requireContract(!gop.found_existing, "two boxes with the same explicit id in one frame");
            gop.value_ptr.* = .{
                .rect = node.rect,
                .clip = clip,
                .measured_w = node.measured_w,
                .measured_h = node.measured_h,
                .content_w = node.content_w,
                .content_h = node.content_h,
                .declared_w = layout.declaredSizeOf(node, true),
                .declared_h = layout.declaredSizeOf(node, false),
            };
        }
        const child_clip = if (node.cfg.clip_children)
            Rect.intersect(clip, layout.contentBox(node.rect, node.cfg.padding))
        else
            clip;
        var it = node.first_child;
        while (it) |c| : (it = c.next_sibling) self.updateRectCache(c, child_clip);
    }

    /// Emit draw cmds (pre-order DFS): bg → (pushClip(content box) if clip_children) → children / leaf →
    /// popClip → border.
    /// `pushClip` uses the content box (rect minus padding), matching `updateRectCache`.
    /// border is emitted after popClip (= ancestor clip) so the frame sits on top of children.
    fn emitNode(self: *Context, node: *const layout.Node, dl: *DrawList) void {
        if (node.leaf) |leaf| {
            switch (leaf) {
                .text => |t| {
                    const clip_self = t.overflow == .clip;
                    if (clip_self) {
                        dl.pushClip(node.rect) catch @panic("Context.endFrame: OOM");
                    }
                    if (node.lines.len == 0) {
                        dl.textEx(
                            .{ .x = node.rect.x, .y = node.rect.y },
                            t.str,
                            t.color,
                            t.font,
                        ) catch @panic("Context.endFrame: OOM");
                    } else {
                        for (node.lines) |line| {
                            dl.textEx(
                                .{ .x = node.rect.x, .y = node.rect.y + line.y_offset },
                                line.text,
                                t.color,
                                t.font,
                            ) catch @panic("Context.endFrame: OOM");
                        }
                    }
                    if (clip_self) dl.popClip();
                },
                .custom => |c| c.draw_fn(c.ctx, dl, node.rect),
            }
            return;
        }
        if (node.cfg.bg) |bg| {
            dl.rectFilledEx(node.rect, bg, .{ .radius = node.cfg.radius }) catch
                @panic("Context.endFrame: OOM");
        }
        if (node.cfg.clip_children) {
            dl.pushClip(layout.contentBox(node.rect, node.cfg.padding)) catch
                @panic("Context.endFrame: OOM");
        }
        var it = node.first_child;
        while (it) |c| : (it = c.next_sibling) self.emitNode(c, dl);
        if (node.cfg.clip_children) dl.popClip();
        if (node.cfg.border) |b| {
            dl.rectOutlineEx(node.rect, b.color, b.thickness, .{ .radius = node.cfg.radius }) catch
                @panic("Context.endFrame: OOM");
        }
        // Focus ring, on the same terms as the border: this frame's rect, after popClip, so it sits
        // above the children and is clipped by the ancestor rather than by the node's own clip.
        // A widget draws no ring of its own — the ring belongs to whichever node carries the id, and
        // updateRectCache has already asserted that only one node per frame does.
        if (self.state.focus_visible and node.cfg.id != 0 and node.cfg.id == self.state.focused_id) {
            dl.rectOutlineEx(
                node.rect,
                self.style.accent.focus,
                self.style.focus_ring_thickness,
                .{ .radius = node.cfg.radius },
            ) catch
                @panic("Context.endFrame: OOM");
        }
    }
};

const frame_arena_vtable: Allocator.VTable = .{
    .alloc = frameArenaAlloc,
    .resize = frameArenaResize,
    .remap = frameArenaRemap,
    .free = frameArenaFree,
};

fn frameArenaAlloc(ctx_ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Context = @ptrCast(@alignCast(ctx_ptr));
    const ptr = self.arena.allocator().rawAlloc(len, alignment, ret_addr) orelse return null;
    self.frame_arena_allocs += 1;
    self.frame_arena_live += len;
    if (self.frame_arena_live > self.frame_arena_peak) self.frame_arena_peak = self.frame_arena_live;
    return ptr;
}

fn frameArenaResize(ctx_ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Context = @ptrCast(@alignCast(ctx_ptr));
    if (!self.arena.allocator().rawResize(memory, alignment, new_len, ret_addr)) return false;
    if (new_len > memory.len) {
        self.frame_arena_live += new_len - memory.len;
        if (self.frame_arena_live > self.frame_arena_peak) self.frame_arena_peak = self.frame_arena_live;
    } else {
        self.frame_arena_live -= memory.len - new_len;
    }
    return true;
}

fn frameArenaRemap(ctx_ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Context = @ptrCast(@alignCast(ctx_ptr));
    const ptr = self.arena.allocator().rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
    if (new_len > memory.len) {
        self.frame_arena_live += new_len - memory.len;
        if (self.frame_arena_live > self.frame_arena_peak) self.frame_arena_peak = self.frame_arena_live;
    } else {
        self.frame_arena_live -= memory.len - new_len;
    }
    return ptr;
}

fn frameArenaFree(ctx_ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *Context = @ptrCast(@alignCast(ctx_ptr));
    self.arena.allocator().rawFree(memory, alignment, ret_addr);
    self.frame_arena_live -= memory.len;
}

pub const ButtonResult = struct {
    clicked: bool = false,
    hovered: bool = false,
    held: bool = false,
};

/// Whether point p is inside the widget's visible hit region (equivalent to membership in `rect ∩ clip`).
///
/// - Outside the effective clip is not hit-testable, same as draw
/// - zero-size rect / clip (w=0 or h=0) is always false → no hover / press acquire / click
/// - overflow children with `clip_children=false` carry the ancestor clip (allowed outside the parent rect)
/// - Partial clips (ScrollArea etc.) are true only inside the viewport clip
///
/// Single source of truth shared by buttonBehavior, TextInput, and SelectableLabel.
fn layerSlotIsFrontmost(candidate: LayerSlot, current: LayerSlot) bool {
    if (candidate.z != current.z) return candidate.z > current.z;
    return candidate.serial > current.serial;
}

fn layerBefore(a: LayerRecord, b: LayerRecord) bool {
    if (a.z != b.z) return a.z < b.z;
    return a.serial < b.serial;
}

pub fn pointHitsVisible(rect: Rect, clip: Rect, p: Vec2) bool {
    return rect.contains(p) and clip.contains(p);
}

/// Dear ImGui-style sync hit-test + button state machine.
/// Evaluates this frame's mouse state against the caller-supplied rect / clip in place and
/// returns ButtonResult synchronously. No post-endFrame re-hit-test or retroactive evaluation after layout settles.
/// rect / clip are normally supplied from the previous-frame rect_cache by widgets' behaviorFromCache.
///
/// Active drag capture: after press acquires active, dragging outside clip/rect does not
/// steal active. Click on release succeeds only when `pointHitsVisible` (inside the visible region).
/// Contract that keeps TextInput range select, slider, and ScrollArea thumb drags working.
pub fn buttonBehavior(ctx: *Context, id: Id, rect: Rect, clip: Rect) ButtonResult {
    return buttonBehaviorImpl(ctx, id, rect, clip, false);
}

/// Button behaviour for a menuBar command target. It shares the normal state machine but may
/// borrow pointer permission only when the target was registered for the current menu route and
/// the pointer is outside that route owner's previous root.
pub fn commandButtonBehavior(
    ctx: *Context,
    id: Id,
    rect: Rect,
    clip: Rect,
    route_key: LayerKey,
) ButtonResult {
    const command_pointer = ctx.commandTargetPointerEnabled(id, route_key, rect, clip);
    const result = buttonBehaviorImpl(ctx, id, rect, clip, command_pointer);
    if (command_pointer and (result.held or result.clicked)) {
        ctx.noteCommandTargetPress(route_key);
    }
    return result;
}

fn buttonBehaviorImpl(ctx: *Context, id: Id, rect: Rect, clip: Rect, command_pointer: bool) ButtonResult {
    ctx.requireFrame("buttonBehavior");
    ctx.requireInteractiveAllowed("buttonBehavior");
    if (!ctx.current_layer_scope.pointer_enabled and !command_pointer) return .{};
    const mp = ctx.input.mouse_pos;
    const hovered_now = pointHitsVisible(rect, clip, mp);
    var result: ButtonResult = .{};
    result.hovered = hovered_now;

    // 1. Apply hover (do not steal while active is on another widget)
    if (hovered_now) {
        if (ctx.state.active_id == 0 or ctx.state.active_id == id) {
            ctx.state.next_hot_id = id; // Last writer wins in draw order
        }
        ctx.state.this_frame_hovered_any = true;
    }

    // 2. Acquire active. Only when the press origin (coordinates at down = mouse_pressed_pos) is
    //    inside the visible region. Using the origin rather than the final mouse_pos prevents
    //    false acquire from same-frame "down outside → move inside".
    if (ctx.state.active_id == 0 and ctx.input.mouse_pressed.left) {
        if (pointHitsVisible(rect, clip, ctx.input.mouse_pressed_pos)) {
            ctx.state.active_id = id;
        }
    }

    // 3. hold / release. While active, keep held even when dragging outside clip (drag capture).
    //    On release edge: clear active + confirm click if visibly hovered at up.
    //    The click test uses `dragPos` (the coordinates at the up edge, not the frame's final
    //    mouse_pos), on the same reasoning as step 2's use of the press origin: a move delivered
    //    after the up in the same frame must not decide whether the click landed.
    if (ctx.state.active_id == id) {
        result.held = true;
        ctx.state.active_submitted = true; // Anti-stick: mark evaluated this frame
        if (ctx.input.mouse_released.left) {
            if (pointHitsVisible(rect, clip, ctx.input.dragPos())) result.clicked = true;
            ctx.state.active_id = 0;
        }
    }
    return result;
}

// ============================================================
// Tests
// ============================================================

const full_clip = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
const btn_rect = Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };

fn testCtx() Context {
    return Context.init(std.testing.allocator, font_mod.default_font);
}

// A synthetic font whose ink height exceeds the popup row token. This exercises the
// natural-height branch without depending on an installed outline font.
const tall_tooltip_dummy: u8 = 0;
const tall_tooltip_vt: Font.VTable = .{
    .measure = struct {
        fn f(_: *const anyopaque, text: []const u8) u32 {
            return 8 * @as(u32, @intCast(text.len));
        }
    }.f,
    .drawTo = struct {
        fn f(_: *const anyopaque, _: font_mod.RenderTarget, _: Vec2, _: []const u8, _: color_mod.Color, _: Rect, _: f32) void {}
    }.f,
    .metrics = struct {
        fn f(_: *const anyopaque) font_mod.Metrics {
            return .{ .line_height = 32, .ascent = 26, .descent = 6 };
        }
    }.f,
};
const tall_tooltip_font: Font = .{ .ptr = &tall_tooltip_dummy, .vtable = &tall_tooltip_vt };

test "draw list access policy covers every phase" {
    const cases = [_]struct {
        phase: DrawPhase,
        main_allowed: bool,
        post_frame_allowed: bool,
    }{
        .{ .phase = .idle, .main_allowed = false, .post_frame_allowed = true },
        .{ .phase = .main_build, .main_allowed = true, .post_frame_allowed = false },
        .{ .phase = .display_only_build, .main_allowed = false, .post_frame_allowed = false },
        .{ .phase = .main_emit, .main_allowed = false, .post_frame_allowed = false },
        .{ .phase = .layer_emit, .main_allowed = false, .post_frame_allowed = false },
        .{ .phase = .final_overlay, .main_allowed = false, .post_frame_allowed = true },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.main_allowed, drawAccessAllowed(case.phase, .main));
        try std.testing.expectEqual(case.post_frame_allowed, drawAccessAllowed(case.phase, .post_frame));
    }
}

test "Context draw list accessors follow frame lifecycle" {
    var ctx = testCtx();
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 0), ctx.postFrameDrawList().cmds.items.len);

    ctx.beginFrame(320, 240);
    const main = ctx.mainDrawList();
    try main.rectFilled(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, Color.rgba(1, 2, 3, 0xFF));
    ctx.endFrame();

    const post = ctx.postFrameDrawList();
    try std.testing.expectEqual(@intFromPtr(main), @intFromPtr(post));
    try std.testing.expectEqual(@as(usize, 1), post.cmds.items.len);
    try post.rectFilled(.{ .x = 4, .y = 0, .w = 4, .h = 4 }, Color.rgba(4, 5, 6, 0xFF));

    ctx.beginFrame(320, 240);
    try std.testing.expectEqual(@as(usize, 0), ctx.mainDrawList().cmds.items.len);
    ctx.endFrame();
}

test "layout: rounded box and focus ring preserve the configured radius" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(100, 60);
    ctx.state.focused_id = 77;
    ctx.state.focus_visible = true;
    ctx.beginBox(.{
        .id = 77,
        .width = .{ .fixed = 40 },
        .height = .{ .fixed = 20 },
        .bg = Color.rgba(0x20, 0x20, 0x20, 0xFF),
        .border = .{ .color = Color.rgba(0xA0, 0xA0, 0xB0, 0xFF), .thickness = 1 },
        .radius = 9,
    });
    ctx.endBox();
    ctx.endFrame();

    try std.testing.expectEqual(@as(usize, 3), ctx.postFrameDrawList().cmds.items.len);
    try std.testing.expectEqual(@as(u32, 9), ctx.postFrameDrawList().cmds.items[0].rect_filled.radius);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[0].rect_filled.aa);
    try std.testing.expectEqual(@as(u32, 9), ctx.postFrameDrawList().cmds.items[1].rect_outline.radius);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[1].rect_outline.aa);
    try std.testing.expectEqual(@as(u32, 9), ctx.postFrameDrawList().cmds.items[2].rect_outline.radius);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[2].rect_outline.aa);
}

test "buttonBehavior: down→up across frames while hovered makes clicked true for one frame only" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;

    // Frame 1: hover + down → held, not clicked
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    var r = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expect(!r.clicked);
    try std.testing.expect(r.held);
    ctx.endFrame();

    // Frame 2: up inside hover → clicked
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    r = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expect(r.clicked);
    ctx.endFrame();

    // Frame 3: clicked returns to false
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    r = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expect(!r.clicked);
    ctx.endFrame();
}

test "buttonBehavior: down→up completed in the same frame still returns clicked" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    const r = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(r.clicked);
    ctx.endFrame();
}

test "buttonBehavior: a move off the widget after the release edge still makes clicked true" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id, btn_rect, full_clip);
    ctx.endFrame();

    // Up inside the button, then one more move that leaves it in the same frame.
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_move = .{ .x = 500, .y = 500, .modifiers = 0 } });
    const r = buttonBehavior(&ctx, id, btn_rect, full_clip);
    ctx.endFrame();

    try std.testing.expect(r.clicked);
    try std.testing.expect(!r.hovered); // hover still follows the frame's final position
}

test "buttonBehavior: a move onto the widget after the release edge does not make clicked true" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id, btn_rect, full_clip);
    ctx.endFrame();

    // Up outside the button, then a move back onto it in the same frame.
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 500, .y = 500, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    const r = buttonBehavior(&ctx, id, btn_rect, full_clip);
    ctx.endFrame();

    try std.testing.expect(!r.clicked);
    try std.testing.expect(r.hovered);
}

test "buttonBehavior: no hover/click outside clip" {
    var ctx = testCtx();
    defer ctx.deinit();
    const narrow_clip = Rect{ .x = 0, .y = 0, .w = 5, .h = 5 };

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } }); // Inside rect but outside clip
    const r = buttonBehavior(&ctx, 1, btn_rect, narrow_clip);
    try std.testing.expect(!r.hovered);
    try std.testing.expect(!ctx.wantsMouse());
    ctx.endFrame();
}

// ── zero-size / overflow / partial clip / drag capture ──

test "pointHitsVisible: zero-size clip is always false" {
    const rect = Rect{ .x = 0, .y = 0, .w = 24, .h = 24 };
    const zero_w = Rect{ .x = 0, .y = 0, .w = 0, .h = 100 };
    const zero_h = Rect{ .x = 0, .y = 0, .w = 100, .h = 0 };
    try std.testing.expect(!pointHitsVisible(rect, zero_w, .{ .x = 5, .y = 5 }));
    try std.testing.expect(!pointHitsVisible(rect, zero_h, .{ .x = 5, .y = 5 }));
    try std.testing.expect(!pointHitsVisible(zero_w, full_clip, .{ .x = 0, .y = 5 }));
}

test "pointHitsVisible: only the visible rect∩clip partial overlap is true" {
    // ScrollArea-like: widget rect [0,100)×[0,40), viewport clip [0,100)×[0,20)
    const rect = Rect{ .x = 0, .y = 0, .w = 100, .h = 40 };
    const vp_clip = Rect{ .x = 0, .y = 0, .w = 100, .h = 20 };
    try std.testing.expect(pointHitsVisible(rect, vp_clip, .{ .x = 10, .y = 10 })); // Visible
    try std.testing.expect(!pointHitsVisible(rect, vp_clip, .{ .x = 10, .y = 30 })); // Inside rect but outside clip
    try std.testing.expect(!pointHitsVisible(rect, vp_clip, .{ .x = 10, .y = 50 })); // Outside both
}

test "pointHitsVisible: overflow allowed (clip_children=false) = outside parent rect OK if inside ancestor clip" {
    // Zero-size parent creates no clip → child clip = screen. Child rect 24x24 is hittable.
    const child = Rect{ .x = 4, .y = 508, .w = 24, .h = 24 };
    try std.testing.expect(pointHitsVisible(child, full_clip, .{ .x = 10, .y = 520 }));
    // A narrow ancestor clip also blocks overflow children outside it
    const narrow = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try std.testing.expect(!pointHitsVisible(child, narrow, .{ .x = 10, .y = 520 }));
}

test "buttonBehavior: no hover/press/click inside a zero-size clip" {
    var ctx = testCtx();
    defer ctx.deinit();
    const zero_clip = Rect{ .x = 0, .y = 0, .w = 0, .h = 50 };

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    const r = buttonBehavior(&ctx, 1, btn_rect, zero_clip);
    try std.testing.expect(!r.hovered);
    try std.testing.expect(!r.held);
    try std.testing.expect(!r.clicked);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id);
    ctx.endFrame();
}

test "buttonBehavior: partial clip allows hover/click only on the visible part" {
    var ctx = testCtx();
    defer ctx.deinit();
    const rect = Rect{ .x = 0, .y = 0, .w = 100, .h = 40 };
    const vp_clip = Rect{ .x = 0, .y = 0, .w = 100, .h = 20 };

    // Click succeeds on the visible part
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    try std.testing.expect(buttonBehavior(&ctx, 1, rect, vp_clip).clicked);
    ctx.endFrame();

    // Press is forbidden inside rect but outside clip
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 30, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 30, .button = 0, .modifiers = 0 } });
    const r = buttonBehavior(&ctx, 2, rect, vp_clip);
    try std.testing.expect(!r.hovered);
    try std.testing.expect(!r.held);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id);
    ctx.endFrame();
}

test "buttonBehavior: active drag keeps capture outside clip; release outside clip does not click" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;
    const rect = Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const clip = Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };

    // frame1: press inside visible → active
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    try std.testing.expect(buttonBehavior(&ctx, id, rect, clip).held);
    try std.testing.expectEqual(id, ctx.state.active_id);
    ctx.endFrame();

    // frame2: drag outside clip → held kept (capture not lost)
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 200, .modifiers = 0 } });
    const mid = buttonBehavior(&ctx, id, rect, clip);
    try std.testing.expect(mid.held);
    try std.testing.expect(!mid.hovered);
    try std.testing.expectEqual(id, ctx.state.active_id);
    ctx.endFrame();

    // frame3: release outside clip → no click; active cleared
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 200, .y = 200, .button = 0, .modifiers = 0 } });
    const up = buttonBehavior(&ctx, id, rect, clip);
    try std.testing.expect(!up.clicked);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id);
    ctx.endFrame();
}

test "rect_cache: with clip_children=false, a zero-size parent leaves child clip as the ancestor" {
    var ctx = testCtx();
    defer ctx.deinit();
    const parent_id: Id = 10;
    const child_id: Id = 11;

    ctx.beginFrame(800, 600);
    // Zero-size parent (clip_children default false) → children may overflow-place
    ctx.beginBox(.{ .id = parent_id, .width = .{ .fixed = 0 }, .height = .{ .fixed = 0 } });
    ctx.beginBox(.{ .id = child_id, .width = .{ .fixed = 24 }, .height = .{ .fixed = 24 } });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    const parent = ctx.rect_cache.get(parent_id).?;
    const child = ctx.rect_cache.get(child_id).?;
    try std.testing.expectEqual(@as(u32, 0), parent.rect.w);
    try std.testing.expectEqual(@as(u32, 0), parent.rect.h);
    try std.testing.expectEqual(@as(u32, 24), child.rect.w);
    try std.testing.expectEqual(@as(u32, 24), child.rect.h);
    // Child clip is screen (not intersected with the zero-size parent)
    try std.testing.expectEqual(@as(u32, 800), child.clip.w);
    try std.testing.expectEqual(@as(u32, 600), child.clip.h);
    try std.testing.expect(pointHitsVisible(child.rect, child.clip, .{
        .x = child.rect.x + 1,
        .y = child.rect.y + 1,
    }));
}

test "rect_cache: with clip_children=true, a zero-size parent empties the child clip" {
    var ctx = testCtx();
    defer ctx.deinit();
    const parent_id: Id = 20;
    const child_id: Id = 21;

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{
        .id = parent_id,
        .width = .{ .fixed = 0 },
        .height = .{ .fixed = 0 },
        .clip_children = true,
    });
    ctx.beginBox(.{ .id = child_id, .width = .{ .fixed = 24 }, .height = .{ .fixed = 24 } });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    const child = ctx.rect_cache.get(child_id).?;
    try std.testing.expect(child.clip.isEmpty() or child.clip.w == 0 or child.clip.h == 0);
    try std.testing.expect(!pointHitsVisible(child.rect, child.clip, .{
        .x = child.rect.x + 1,
        .y = child.rect.y + 1,
    }));
}

test "rect_cache: with clip_children=true, a partially clipped child gets the viewport intersection clip" {
    var ctx = testCtx();
    defer ctx.deinit();
    const vp_id: Id = 30;
    const item_id: Id = 31;

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{
        .id = vp_id,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 20 },
        .clip_children = true,
    });
    // Child taller than parent (partial clip)
    ctx.beginBox(.{ .id = item_id, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    const item = ctx.rect_cache.get(item_id).?;
    try std.testing.expectEqual(@as(u32, 40), item.rect.h);
    // child clip = intersect(screen, parent.rect) → h=20
    try std.testing.expectEqual(@as(u32, 20), item.clip.h);
    try std.testing.expect(pointHitsVisible(item.rect, item.clip, .{ .x = item.rect.x + 1, .y = item.rect.y + 1 }));
    try std.testing.expect(!pointHitsVisible(item.rect, item.clip, .{ .x = item.rect.x + 1, .y = item.rect.y + 30 }));
}

test "rect_cache: clip_children clips to the content box inside padding" {
    var ctx = testCtx();
    defer ctx.deinit();
    const vp_id: Id = 40;
    const item_id: Id = 41;

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{
        .id = vp_id,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 20 },
        .padding = .{ 0, 8, 0, 0 },
        .clip_children = true,
    });
    ctx.beginBox(.{ .id = item_id, .width = .{ .fixed = 100 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    const item = ctx.rect_cache.get(item_id).?;
    try std.testing.expectEqual(@as(u32, 92), item.clip.w);
    try std.testing.expect(pointHitsVisible(item.rect, item.clip, .{ .x = item.rect.x + 1, .y = item.rect.y + 1 }));
    try std.testing.expect(!pointHitsVisible(item.rect, item.clip, .{ .x = item.clip.x + @as(i32, @intCast(item.clip.w)), .y = item.rect.y + 1 }));
}

test "Context.wantsMouse: true from the hover-start frame" {
    var ctx = testCtx();
    defer ctx.deinit();

    // Outside hover
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 200, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(!ctx.wantsMouse());
    ctx.endFrame();

    // Inside hover (start frame)
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(ctx.wantsMouse());
    ctx.endFrame();
}

test "Context.wantsMouse: stays true while hover continues after active clears" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;

    // Frame 1: hover + down → acquire active
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expect(ctx.wantsMouse());
    try std.testing.expectEqual(id, ctx.state.active_id);
    ctx.endFrame();

    // Frame 2: up inside hover → active clears but hover continues → wantsMouse true
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id);
    try std.testing.expect(ctx.wantsMouse());
    ctx.endFrame();
}

test "Context: beginFrameAt time, focus claim, and ID state persistence" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrameAt(320, 200, 12.5);
    try std.testing.expectEqual(@as(f64, 12.5), ctx.now());
    try std.testing.expect(ctx.claimFocus(77));
    ctx.perIdState(77).selection = .{ .anchor = 2, .extent = 5 };
    ctx.endFrame();

    ctx.beginFrameAt(320, 200, 13.0);
    try std.testing.expectEqual(@as(Id, 77), ctx.state.focused_id);
    try std.testing.expectEqual(@as(usize, 2), ctx.perIdState(77).selection.anchor);
    try std.testing.expectEqual(@as(usize, 5), ctx.perIdState(77).selection.extent);
    ctx.endFrame();
}

test "Context: endFrame trim keeps focused hidden state" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.per_id_state.max_entries = 2;
    ctx.per_id_state.trim_to = 1;

    ctx.beginFrame(320, 200);
    try std.testing.expect(ctx.claimFocus(50));
    ctx.perIdState(50).caret = 9;
    _ = ctx.perIdState(51);
    ctx.endFrame();

    // frame 2: keep focus; 50 is hidden; new IDs exceed the cap
    ctx.beginFrame(320, 200);
    try std.testing.expectEqual(@as(Id, 50), ctx.state.focused_id);
    _ = ctx.perIdState(60);
    _ = ctx.perIdState(61);
    _ = ctx.perIdState(62);
    ctx.endFrame();

    try std.testing.expect(ctx.per_id_state.get(50) != null);
    try std.testing.expectEqual(@as(usize, 9), ctx.per_id_state.get(50).?.caret);
    // Unprotected old 51 is gone
    try std.testing.expect(ctx.per_id_state.get(51) == null);
}

test "Context: hide then re-show under capacity keeps PerIdState" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(320, 200);
    ctx.perIdState(88).selection = .{ .anchor = 1, .extent = 4 };
    ctx.perIdState(88).scroll_x = 16;
    ctx.endFrame();

    // Hidden frame
    ctx.beginFrame(320, 200);
    ctx.endFrame();

    ctx.beginFrame(320, 200);
    try std.testing.expectEqual(@as(usize, 1), ctx.perIdState(88).selection.anchor);
    try std.testing.expectEqual(@as(usize, 4), ctx.perIdState(88).selection.extent);
    try std.testing.expectEqual(@as(i32, 16), ctx.perIdState(88).scroll_x);
    ctx.endFrame();
}

test "Context.beginFrame: virtual time is frame index / 60" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(320, 200);
    try std.testing.expectEqual(@as(f64, 0.0), ctx.now());
    ctx.endFrame();
    ctx.beginFrame(320, 200);
    try std.testing.expectEqual(@as(f64, 1.0 / 60.0), ctx.now());
    ctx.endFrame();
}

test "buttonBehavior: while active, another widget does not steal hot" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id_a: Id = 1;
    const id_b: Id = 2;
    const rect_a = Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const rect_b = Rect{ .x = 0, .y = 60, .w = 100, .h = 50 };

    // Frame 1: hover+down on A → active_id = A
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id_a, rect_a, full_clip);
    try std.testing.expectEqual(id_a, ctx.state.active_id);
    ctx.endFrame();

    // Frame 2: move onto B (A still held). next_hot does not become B even over B
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 70, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id_a, rect_a, full_clip);
    _ = buttonBehavior(&ctx, id_b, rect_b, full_clip);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.next_hot_id);
    ctx.endFrame();
}

test "Context.beginFrame: screen_w/h are logical root clip size" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(320, 240);
    try std.testing.expectEqual(@as(u32, 320), ctx.screen_w);
    try std.testing.expectEqual(@as(u32, 240), ctx.screen_h);
    const root = ctx.mainDrawList().clip_stack.items[0];
    try std.testing.expectEqual(@as(u32, 320), root.w);
    try std.testing.expectEqual(@as(u32, 240), root.h);
    try std.testing.expectEqual(@as(i32, 320), ctx.layout_root.?.cfg.width.fixed);
    try std.testing.expectEqual(@as(i32, 240), ctx.layout_root.?.cfg.height.fixed);
    ctx.endFrame();
}

test "Context: beginFrame resets; endFrame keeps draw state/id_stack/state" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    try ctx.mainDrawList().rectFilled(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, color_mod.Color.rgba(0xFF, 0, 0, 0xFF));
    ctx.id_stack.push("scope");
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    ctx.endFrame();

    // Still valid after endFrame (referenceable until the next beginFrame)
    try std.testing.expect(ctx.postFrameDrawList().cmds.items.len > 0);
    try std.testing.expect(ctx.id_stack.stack.items.len > 0);
    try std.testing.expect(ctx.state.this_frame_hovered_any);

    // Reset on the next beginFrame
    ctx.beginFrame(800, 600);
    try std.testing.expectEqual(@as(usize, 0), ctx.mainDrawList().cmds.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.id_stack.stack.items.len);
    try std.testing.expect(!ctx.state.this_frame_hovered_any);
    ctx.endFrame();
}

test "buttonBehavior: down outside → move inside → up (same frame) does not click" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 200, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 200, .y = 200, .button = 0, .modifiers = 0 } }); // Origin is outside
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } }); // Move inside
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    const r = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(!r.clicked);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id);
    ctx.endFrame();
}

test "buttonBehavior: down inside → move outside (same frame) still acquires active at the press origin" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } }); // Origin is inside
    ctx.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 200, .modifiers = 0 } }); // Drag outside
    const r = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(r.held);
    try std.testing.expectEqual(@as(Id, 1), ctx.state.active_id);
    ctx.endFrame();
}

test "Context: if the active widget is released without evaluation, endFrame clears active_id" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;

    // Frame 1: hover+down → acquire active
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expectEqual(id, ctx.state.active_id);
    ctx.endFrame();

    // Frame 2: do not call the widget (hidden); release the button
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    // Do not call buttonBehavior(id) (widget gone)
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id); // Stickiness cleared
}

// ──────────────────────────────────────────────
// Layout integration tests
// ──────────────────────────────────────────────

test "layout: an explicit-ID box is available via getNodeRect after endFrame" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    const id = ctx.id_stack.make("panel");
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = 200 }, .height = .{ .fixed = 100 } });
    ctx.endBox();
    // Unregistered before endFrame (first frame)
    try std.testing.expectEqual(@as(?Rect, null), ctx.getNodeRect(id));
    ctx.endFrame();

    const r = ctx.getNodeRect(id).?;
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(i32, 0), r.y);
    try std.testing.expectEqual(@as(u32, 200), r.w);
    try std.testing.expectEqual(@as(u32, 100), r.h);
}

test "layout: getNodeRect returns null for auto ID (cfg.id=0), unknown ID, and 0" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 50 } }); // Auto ID
    ctx.endBox();
    ctx.endFrame();

    try std.testing.expectEqual(@as(?Rect, null), ctx.getNodeRect(0));
    try std.testing.expectEqual(@as(?Rect, null), ctx.getNodeRect(12345)); // Unknown ID
}

test "layout: rect cache returns previous-frame values across beginFrame (sync hit-test contract)" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 42;

    // Frame 1: place at 200x100
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = 200 }, .height = .{ .fixed = 100 } });
    ctx.endBox();
    ctx.endFrame();

    // First half of frame 2 (widget-call timing): previous-frame value is available
    ctx.beginFrame(800, 600);
    const prev = ctx.getNodeRect(id).?;
    try std.testing.expectEqual(@as(u32, 200), prev.w);
    // Sync hit-test against the previous-frame rect succeeds (click confirms)
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    const res = buttonBehavior(&ctx, id, prev, full_clip);
    try std.testing.expect(res.clicked);
    // This frame places at a new size
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = 300 }, .height = .{ .fixed = 150 } });
    ctx.endBox();
    ctx.endFrame();

    // After endFrame the cache holds this frame's values
    try std.testing.expectEqual(@as(u32, 300), ctx.getNodeRect(id).?.w);
}

test "layout: clip_children bakes the parent rect into children's draw cmds" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 40 },
        .clip_children = true,
        .bg = Color.rgba(0x20, 0x20, 0x20, 0xFF),
    });
    ctx.label("a long text that overflows the box");
    ctx.endBox();
    ctx.endFrame();

    // Emit order: bg (clip = screen) → text (clip already intersected with parent rect)
    try std.testing.expectEqual(@as(usize, 2), ctx.postFrameDrawList().cmds.items.len);
    const bg_clip = ctx.postFrameDrawList().cmds.items[0].rect_filled.clip;
    try std.testing.expectEqual(@as(u32, 800), bg_clip.w);
    const text_clip = ctx.postFrameDrawList().cmds.items[1].text.clip;
    try std.testing.expectEqual(@as(i32, 0), text_clip.x);
    try std.testing.expectEqual(@as(u32, 100), text_clip.w);
    try std.testing.expectEqual(@as(u32, 40), text_clip.h);
}

test "position: clip_children clips an overflowing positioned child's draw commands" {
    var ctx = testCtx();
    defer ctx.deinit();
    const host: Id = 0xA101;
    const badge: Id = 0xA102;
    ctx.beginFrame(200, 200);
    ctx.beginBox(.{
        .id = host,
        .width = .{ .fixed = 40 },
        .height = .{ .fixed = 40 },
        .clip_children = true,
        .bg = Color.rgba(0x20, 0x20, 0x20, 0xFF),
    });
    ctx.beginBox(.{
        .id = badge,
        .position = .{ .top = .{ .length = .{ .px = -8 } }, .right = .{ .length = .{ .px = -16 } } },
        .width = .{ .fixed = 20 },
        .height = .{ .fixed = 20 },
        .bg = Color.rgba(0xC0, 0x30, 0x30, 0xFF),
    });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    const host_r = ctx.getNodeRect(host).?;
    const badge_r = ctx.getNodeRect(badge).?;
    try std.testing.expect(badge_r.x + @as(i32, @intCast(badge_r.w)) > host_r.x + @as(i32, @intCast(host_r.w)));
    var found = false;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd != .rect_filled) continue;
        if (cmd.rect_filled.paint != .solid or !std.meta.eql(cmd.rect_filled.paint.solid, Color.rgba(0xC0, 0x30, 0x30, 0xFF))) continue;
        try std.testing.expectEqual(@as(i32, 0), cmd.rect_filled.clip.x);
        try std.testing.expectEqual(@as(u32, 40), cmd.rect_filled.clip.w);
        try std.testing.expectEqual(@as(u32, 40), cmd.rect_filled.clip.h);
        found = true;
    }
    try std.testing.expect(found);
}

test "position: an explicit id is cached and hit-tested" {
    var ctx = testCtx();
    defer ctx.deinit();
    const host: Id = 0xA201;
    const badge: Id = 0xA202;

    ctx.beginFrame(200, 200);
    ctx.beginBox(.{
        .id = host,
        .width = .{ .fixed = 80 },
        .height = .{ .fixed = 40 },
        .bg = Color.rgba(0x30, 0x30, 0x38, 0xFF),
    });
    ctx.label("host");
    ctx.beginBox(.{
        .id = badge,
        .position = .{ .top = .{ .length = .{ .px = -4 } }, .right = .{ .length = .{ .px = -4 } } },
        .width = .{ .fixed = 16 },
        .height = .{ .fixed = 16 },
        .bg = Color.rgba(0xC0, 0x30, 0x30, 0xFF),
    });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    const cached = ctx.getNodeCachedRect(badge).?;
    try std.testing.expectEqual(@as(u32, 16), cached.rect.w);
    try std.testing.expectEqual(@as(i32, 80 - 16 + 4), cached.rect.x);
    try std.testing.expectEqual(@as(i32, -4), cached.rect.y);

    const cx = cached.rect.x + 8;
    const cy = cached.rect.y + 8;
    ctx.beginFrame(200, 200);
    ctx.pushEvent(.{ .mouse_move = .{ .x = cx, .y = cy, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = cx, .y = cy, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_up = .{ .x = cx, .y = cy, .button = 0, .modifiers = 0 } });
    const res = buttonBehavior(&ctx, badge, cached.rect, cached.clip);
    ctx.endFrame();
    try std.testing.expect(res.clicked);
}

test "position: a tree with none keeps the in-flow rect and DrawCmd contract" {
    var ctx = testCtx();
    defer ctx.deinit();
    const row: Id = 0xA301;
    const left: Id = 0xA302;
    const right: Id = 0xA303;
    const red = Color.rgba(0x10, 0x00, 0x00, 0xFF);
    const blue = Color.rgba(0x00, 0x10, 0x00, 0xFF);
    const green = Color.rgba(0x00, 0x00, 0x10, 0xFF);

    ctx.beginFrame(200, 40);
    ctx.beginBox(.{
        .id = row,
        .direction = .row,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 40 },
        .gap = 4,
        .bg = red,
    });
    ctx.beginBox(.{ .id = left, .width = .{ .fixed = 40 }, .height = .{ .fixed = 16 }, .bg = blue });
    ctx.label("ab");
    ctx.endBox();
    ctx.beginBox(.{ .id = right, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .bg = green });
    ctx.label("cd");
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    try std.testing.expect(!ctx.layout_root.?.has_positioned_child);
    try std.testing.expectEqual(ctx.layout_root.?.child_count, ctx.layout_root.?.flow_child_count);

    const row_r = ctx.getNodeRect(row).?;
    const left_r = ctx.getNodeRect(left).?;
    const right_r = ctx.getNodeRect(right).?;
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 200, .h = 40 }, row_r);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 40, .h = 16 }, left_r);
    try std.testing.expectEqual(Rect{ .x = 44, .y = 0, .w = 156, .h = 40 }, right_r);

    try std.testing.expectEqual(@as(usize, 5), ctx.postFrameDrawList().cmds.items.len);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[0] == .rect_filled);
    try std.testing.expectEqual(row_r, ctx.postFrameDrawList().cmds.items[0].rect_filled.rect);
    try std.testing.expectEqual(red, ctx.postFrameDrawList().cmds.items[0].rect_filled.paint.solid);
    try std.testing.expectEqual(left_r, ctx.postFrameDrawList().cmds.items[1].rect_filled.rect);
    try std.testing.expectEqual(blue, ctx.postFrameDrawList().cmds.items[1].rect_filled.paint.solid);
    try std.testing.expectEqualStrings("ab", ctx.postFrameDrawList().cmds.items[2].text.text);
    try std.testing.expectEqual(@as(i32, 0), ctx.postFrameDrawList().cmds.items[2].text.pos.x);
    try std.testing.expectEqual(@as(i32, 0), ctx.postFrameDrawList().cmds.items[2].text.pos.y);
    try std.testing.expectEqual(right_r, ctx.postFrameDrawList().cmds.items[3].rect_filled.rect);
    try std.testing.expectEqual(green, ctx.postFrameDrawList().cmds.items[3].rect_filled.paint.solid);
    try std.testing.expectEqualStrings("cd", ctx.postFrameDrawList().cmds.items[4].text.text);
    try std.testing.expectEqual(@as(i32, 44), ctx.postFrameDrawList().cmds.items[4].text.pos.x);
    try std.testing.expectEqual(@as(i32, 0), ctx.postFrameDrawList().cmds.items[4].text.pos.y);
}

test "layout: label dupes the string onto the arena (immune to later caller-buffer rewrites)" {
    var ctx = testCtx();
    defer ctx.deinit();

    var buf = "hello".*;
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{});
    ctx.label(&buf);
    ctx.endBox();
    buf[0] = 'X'; // Rewrite the caller buffer before endFrame (emit)
    ctx.endFrame();

    try std.testing.expectEqualStrings("hello", ctx.postFrameDrawList().cmds.items[0].text.text);
}

test "layout: frames unused by the layout API emit no draws and keep the rect cache" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 7;

    // Frame 1: layout used
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expect(ctx.getNodeRect(id) != null);

    // Frame 2: layout unused (manual DrawList compatibility)
    ctx.beginFrame(800, 600);
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 0), ctx.postFrameDrawList().cmds.items.len);
    try std.testing.expect(ctx.getNodeRect(id) != null); // Keep previous values
}

test "layout: custom leaf is called during endFrame with the final rect" {
    var ctx = testCtx();
    defer ctx.deinit();

    const Capture = struct {
        rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        fn drawFn(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.rect = rect;
            dl.rectFilled(rect, Color.rgba(0xFF, 0, 0, 0xFF)) catch @panic("OOM");
        }
    };
    var cap: Capture = .{};

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{ .direction = .row, .padding = .{ 5, 5, 5, 5 } });
    ctx.custom(.{ .x = 64, .y = 32 }, Capture.drawFn, &cap);
    ctx.endBox();
    ctx.endFrame();

    // size is used for measure; placed inside padding
    try std.testing.expectEqual(@as(i32, 5), cap.rect.x);
    try std.testing.expectEqual(@as(i32, 5), cap.rect.y);
    try std.testing.expectEqual(@as(u32, 64), cap.rect.w);
    try std.testing.expectEqual(@as(u32, 32), cap.rect.h);
    try std.testing.expectEqual(@as(usize, 1), ctx.postFrameDrawList().cmds.items.len);
}

// ──────────────────────────────────────────────
// Context-side widget-layer changes
// ──────────────────────────────────────────────

test "layout: border emits in order bg → children → border" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 40 },
        .bg = Color.rgba(0x20, 0x20, 0x20, 0xFF),
        .border = .{ .color = Color.rgba(0xA0, 0xA0, 0xB0, 0xFF), .thickness = 2 },
    });
    ctx.label("x");
    ctx.endBox();
    ctx.endFrame();

    try std.testing.expectEqual(@as(usize, 3), ctx.postFrameDrawList().cmds.items.len);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[0] == .rect_filled);
    try std.testing.expect(ctx.postFrameDrawList().cmds.items[1] == .text);
    const outline = ctx.postFrameDrawList().cmds.items[2].rect_outline;
    try std.testing.expectEqual(@as(u32, 2), outline.thickness);
    try std.testing.expectEqual(@as(u32, 100), outline.rect.w);
}

test "label: default color follows the primary text token" {
    var ctx = testCtx();
    defer ctx.deinit();

    const red = Color.rgba(0xFF, 0x00, 0x00, 0xFF);
    ctx.style.text_tokens.primary = red;
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{});
    ctx.label("hello");
    ctx.endBox();
    ctx.endFrame();

    try std.testing.expectEqual(red, ctx.postFrameDrawList().cmds.items[0].text.color);
}

// ──────────────────────────────────────────────
// tooltip
// ──────────────────────────────────────────────

fn tooltipHasText(ctx: *Context, expected: []const u8) bool {
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        // Path commands are not tooltip labels; only `.text` is inspected.
        if (cmd == .text and std.mem.eql(u8, cmd.text.text, expected)) return true;
    }
    return false;
}

/// The background the tooltip's text sits on, found by walking back from the text to the
/// nearest filled rect. The tooltip is emitted as a layer — a box with a background, its
/// children, then its border — so the background is the last fill before the text rather
/// than a fixed number of commands away.
fn tooltipOverlayBgRect(ctx: *Context, tip: []const u8) ?Rect {
    var i: usize = 0;
    while (i < ctx.postFrameDrawList().cmds.items.len) : (i += 1) {
        const cmd = ctx.postFrameDrawList().cmds.items[i];
        if (cmd != .text or !std.mem.eql(u8, cmd.text.text, tip)) continue;
        var j = i;
        while (j > 0) {
            j -= 1;
            if (ctx.postFrameDrawList().cmds.items[j] == .rect_filled) {
                return ctx.postFrameDrawList().cmds.items[j].rect_filled.rect;
            }
        }
        return null;
    }
    return null;
}

fn hoverButtonWithTip(ctx: *Context, id: Id, label: []const u8, tip: []const u8, now_s: f64) void {
    ctx.beginFrameAt(800, 600, now_s);
    const r = ctx.getNodeRect(id) orelse Rect{ .x = 0, .y = 0, .w = 48, .h = 24 };
    const cx = r.x + @as(i32, @intCast(r.w / 2));
    const cy = r.y + @as(i32, @intCast(r.h / 2));
    ctx.pushEvent(.{ .mouse_move = .{ .x = cx, .y = cy, .modifiers = 0 } });
    _ = ctx.buttonId(id, label, .{});
    ctx.tooltip(tip);
    ctx.endFrame();
}

test "tooltip: hidden on the first hover frame" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();

    hoverButtonWithTip(&ctx, 1, "Btn", "hello tip", 0.0);
    try std.testing.expect(!tooltipHasText(&ctx, "hello tip"));
}

test "tooltip: 500ms boundary at 0.0→0.4→0.5 (hidden below; shown at/after)" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();

    hoverButtonWithTip(&ctx, 1, "Btn", "tip", 0.0);
    try std.testing.expect(!tooltipHasText(&ctx, "tip"));

    hoverButtonWithTip(&ctx, 1, "Btn", "tip", 0.4);
    try std.testing.expect(!tooltipHasText(&ctx, "tip"));

    hoverButtonWithTip(&ctx, 1, "Btn", "tip", 0.5);
    try std.testing.expect(tooltipHasText(&ctx, "tip"));
}

const LayerFixture = struct {
    key: u64,
    z: i32 = 0,
    anchor_id: ?Id = null,
    point: Vec2 = .{ .x = 0, .y = 0 },
    w: i32 = 20,
    h: i32 = 10,
    box_id: Id = 0,

    fn build(self: LayerFixture, ctx: *Context) void {
        ctx.beginBox(.{
            .layer = &.{
                .key = .{ .value = self.key },
                .z = self.z,
                .placement = .{
                    .source = if (self.anchor_id) |a| .{ .id = a } else .{ .point = self.point },
                    .flip = .none,
                },
            },
            .id = self.box_id,
            .width = .{ .fixed = self.w },
            .height = .{ .fixed = self.h },
        });
        ctx.endBox();
    }
};

test "layer: the marker specification is copied during beginBox" {
    var ctx = testCtx();
    defer ctx.deinit();

    var spec: LayerSpec = .{
        .key = .{ .value = 901 },
        .z = 4,
        .placement = .{ .source = .{ .point = .{ .x = 11, .y = 13 } }, .flip = .none },
    };
    ctx.beginFrameAt(400, 300, 0.0);
    ctx.beginBox(.{
        .layer = &spec,
        .id = 9010,
        .width = .{ .fixed = 20 },
        .height = .{ .fixed = 10 },
    });
    // The caller may reuse or rewrite the temporary after beginBox. Later phases must use the
    // copy in the frame record, not the pointer retained in Node.cfg.
    spec.key = .{ .value = 902 };
    spec.z = 99;
    spec.placement.source = .{ .point = .{ .x = 101, .y = 103 } };
    ctx.endBox();
    ctx.endFrame();

    try std.testing.expectEqual(@as(u64, 901), ctx.layers[0].key.value);
    try std.testing.expectEqual(@as(i32, 4), ctx.layers[0].z);
    try std.testing.expectEqual(@as(i32, 11), ctx.getNodeRect(9010).?.x);
    try std.testing.expectEqual(@as(i32, 13), ctx.getNodeRect(9010).?.y);
    try std.testing.expect(@sizeOf(?*const LayerSpec) < @sizeOf(?LayerSpec));
    try std.testing.expect(@sizeOf(BoxConfig) <= 176);
}

test "layer: a previous modal route is selected before current markers" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrameAt(400, 300, 0.0);
    const first_spec: LayerSpec = .{
        .key = .{ .value = 903 },
        .input = .modal,
        .dismiss_on_outside = true,
        .placement = .{ .source = .{ .point = .{ .x = 10, .y = 10 } }, .flip = .none },
    };
    try std.testing.expectEqual(ctx.current_layer_scope.pointer_enabled, ctx.current_layer_scope.route_active);
    ctx.beginBox(.{ .layer = &first_spec, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    try std.testing.expectEqual(ctx.current_layer_scope.pointer_enabled, ctx.current_layer_scope.route_active);
    ctx.endBox();
    try std.testing.expectEqual(ctx.current_layer_scope.pointer_enabled, ctx.current_layer_scope.route_active);
    ctx.endFrame();

    ctx.pushEvent(.{ .mouse_down = .{ .x = 100, .y = 100, .button = 0, .modifiers = 0 } });
    ctx.beginFrameAt(400, 300, 0.1);
    try std.testing.expect(ctx.layer_route.frontmost_key != null);
    try std.testing.expect(!ctx.current_layer_scope.pointer_enabled);
    try std.testing.expectEqual(ctx.current_layer_scope.pointer_enabled, ctx.current_layer_scope.route_active);
    try std.testing.expect(ctx.layerDismissed(.{ .value = 903 }));

    const second_spec: LayerSpec = .{
        .key = .{ .value = 903 },
        .input = .modal,
        .dismiss_on_outside = true,
        .placement = .{ .source = .{ .point = .{ .x = 10, .y = 10 } }, .flip = .none },
    };
    ctx.beginBox(.{ .layer = &second_spec, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    try std.testing.expect(ctx.current_layer_scope.pointer_enabled);
    try std.testing.expectEqual(ctx.current_layer_scope.pointer_enabled, ctx.current_layer_scope.route_active);
    ctx.endBox();
    try std.testing.expect(!ctx.current_layer_scope.pointer_enabled);
    try std.testing.expectEqual(ctx.current_layer_scope.pointer_enabled, ctx.current_layer_scope.route_active);
    ctx.endFrame();
}

test "layer: command target yields only to an inside hit" {
    var ctx = testCtx();
    defer ctx.deinit();
    const title_id: Id = 9051;
    const item_id: Id = 9052;
    const menu_key: LayerKey = .{ .value = 9053 };
    const spec: LayerSpec = .{
        .key = menu_key,
        .input = .modal,
        .dismiss_on_outside = true,
        .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } }, .flip = .none },
    };

    ctx.beginFrameAt(400, 300, 0.0);
    _ = ctx.buttonId(title_id, "File", .{});
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 120 }, .height = .{ .fixed = 60 } });
    _ = ctx.buttonId(item_id, "Open", .{});
    ctx.endBox();
    ctx.endFrame();

    const title = ctx.getNodeRect(title_id).?;
    ctx.pushEvent(.{ .mouse_down = .{ .x = title.x + 8, .y = title.y + 8, .button = 0, .modifiers = 0 } });
    ctx.beginFrameAt(400, 300, 0.1);
    ctx.registerCommandTarget(title_id, menu_key);
    const command = commandButtonBehavior(&ctx, title_id, title, Rect{ .x = 0, .y = 0, .w = 400, .h = 300 }, menu_key);
    try std.testing.expect(!command.hovered and !command.held and !command.clicked);
    try std.testing.expect(!ctx.layerDismissed(menu_key));
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 120 }, .height = .{ .fixed = 60 } });
    const item = ctx.buttonId(item_id, "Open", .{});
    try std.testing.expect(item.hovered);
    try std.testing.expect(item.held);
    ctx.endBox();
    ctx.endFrame();
}

test "layer: command target exclusively consumes an outside retarget press" {
    var ctx = testCtx();
    defer ctx.deinit();
    const title_id: Id = 9061;
    const menu_key: LayerKey = .{ .value = 9062 };
    const spec: LayerSpec = .{
        .key = menu_key,
        .input = .modal,
        .dismiss_on_outside = true,
        .placement = .{ .source = .{ .point = .{ .x = 120, .y = 120 } }, .flip = .none },
    };

    ctx.beginFrameAt(400, 300, 0.0);
    _ = ctx.buttonId(title_id, "File", .{});
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 80 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    ctx.endFrame();

    const title = ctx.getNodeRect(title_id).?;
    ctx.pushEvent(.{ .mouse_down = .{ .x = title.x + 8, .y = title.y + 8, .button = 0, .modifiers = 0 } });
    ctx.beginFrameAt(400, 300, 0.1);
    try std.testing.expect(ctx.layerDismissed(menu_key));
    ctx.registerCommandTarget(title_id, menu_key);
    const command = commandButtonBehavior(&ctx, title_id, title, Rect{ .x = 0, .y = 0, .w = 400, .h = 300 }, menu_key);
    try std.testing.expect(command.held);
    try std.testing.expect(!ctx.layerDismissed(menu_key));
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 80 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    ctx.endFrame();
}

test "layer: command target does not bypass a different modal route owner" {
    var ctx = testCtx();
    defer ctx.deinit();
    const title_id: Id = 9071;
    const owner_key: LayerKey = .{ .value = 9072 };
    const menu_key: LayerKey = .{ .value = 9073 };
    const spec: LayerSpec = .{
        .key = owner_key,
        .input = .modal,
        .placement = .{ .source = .{ .point = .{ .x = 120, .y = 120 } }, .flip = .none },
    };

    ctx.beginFrameAt(400, 300, 0.0);
    _ = ctx.buttonId(title_id, "File", .{});
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 80 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    ctx.endFrame();

    const title = ctx.getNodeRect(title_id).?;
    ctx.pushEvent(.{ .mouse_down = .{ .x = title.x + 8, .y = title.y + 8, .button = 0, .modifiers = 0 } });
    ctx.beginFrameAt(400, 300, 0.1);
    ctx.registerCommandTarget(title_id, menu_key);
    const command = commandButtonBehavior(&ctx, title_id, title, Rect{ .x = 0, .y = 0, .w = 400, .h = 300 }, menu_key);
    try std.testing.expect(!command.hovered and !command.held and !command.clicked);
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 80 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    ctx.endFrame();
}

test "layer: visible context and flipped menu roots win over a title target" {
    const scenarios = [_]struct {
        placement: LayerPlacement,
        width: i32,
        height: i32,
    }{
        .{
            .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } }, .flip = .none, .shift = .none },
            .width = 120,
            .height = 60,
        },
        .{
            .placement = .{ .source = .{ .point = .{ .x = 399, .y = 299 } }, .flip = .main_axis, .shift = .both_axes },
            .width = 120,
            .height = 60,
        },
    };

    for (scenarios) |scenario| {
        var ctx = testCtx();
        defer ctx.deinit();
        const menu_key: LayerKey = .{ .value = 9081 };
        const spec: LayerSpec = .{
            .key = menu_key,
            .input = .modal,
            .dismiss_on_outside = true,
            .placement = scenario.placement,
        };
        ctx.beginFrameAt(400, 300, 0.0);
        ctx.beginBox(.{
            .layer = &spec,
            .width = .{ .fixed = scenario.width },
            .height = .{ .fixed = scenario.height },
        });
        _ = ctx.buttonId(9083, "visible item", .{});
        ctx.endBox();
        ctx.endFrame();

        const root = ctx.layerPrevRect(menu_key).?;
        const item_rect = ctx.getNodeRect(9083).?;
        const point = Vec2{
            .x = item_rect.x + @as(i32, @intCast(item_rect.w / 2)),
            .y = item_rect.y + @as(i32, @intCast(item_rect.h / 2)),
        };
        try std.testing.expect(root.contains(point));
        ctx.pushEvent(.{ .mouse_down = .{ .x = point.x, .y = point.y, .button = 0, .modifiers = 0 } });
        ctx.beginFrameAt(400, 300, 0.1);
        ctx.registerCommandTarget(9082, menu_key);
        const title = commandButtonBehavior(
            &ctx,
            9082,
            .{ .x = point.x, .y = point.y, .w = 1, .h = 1 },
            .{ .x = 0, .y = 0, .w = 400, .h = 300 },
            menu_key,
        );
        try std.testing.expect(!title.hovered and !title.held and !title.clicked);
        try std.testing.expect(!ctx.layerDismissed(menu_key));
        ctx.beginBox(.{
            .layer = &spec,
            .width = .{ .fixed = scenario.width },
            .height = .{ .fixed = scenario.height },
        });
        const item = ctx.buttonId(9083, "visible item", .{});
        try std.testing.expect(item.held);
        ctx.endBox();
        ctx.endFrame();
    }
}

test "layer: a dialog route absorbs menu title targets" {
    var ctx = testCtx();
    defer ctx.deinit();
    const dialog_key: LayerKey = .{ .value = 9091 };
    const menu_key: LayerKey = .{ .value = 9092 };
    const spec: LayerSpec = .{
        .key = dialog_key,
        .input = .modal,
        .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } }, .flip = .none, .shift = .none },
    };

    ctx.beginFrameAt(400, 300, 0.0);
    ctx.beginBox(.{
        .layer = &spec,
        .width = .{ .fixed = 400 },
        .height = .{ .fixed = 300 },
    });
    _ = ctx.buttonId(9094, "dialog", .{});
    ctx.endBox();
    ctx.endFrame();

    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.beginFrameAt(400, 300, 0.1);
    ctx.registerCommandTarget(9093, menu_key);
    const title = commandButtonBehavior(
        &ctx,
        9093,
        .{ .x = 0, .y = 0, .w = 80, .h = 24 },
        .{ .x = 0, .y = 0, .w = 400, .h = 300 },
        menu_key,
    );
    try std.testing.expect(!title.hovered and !title.held and !title.clicked);
    ctx.beginBox(.{
        .layer = &spec,
        .width = .{ .fixed = 400 },
        .height = .{ .fixed = 300 },
    });
    const dialog_content = ctx.buttonId(9094, "dialog", .{});
    try std.testing.expect(dialog_content.held);
    ctx.endBox();
    ctx.endFrame();
}

test "layer: the latched route does not retain a compacted slot index" {
    try std.testing.expect(@hasField(LayerRoute, "frontmost_key"));
    try std.testing.expect(!@hasField(LayerRoute, "frontmost_slot"));
}

test "layer: presence-only lifecycle has no retained open bit" {
    // A marker submitted in this frame is the only presence source; an open bit would duplicate
    // consumer state and reintroduce delayed or undefined lifecycle cases.
    try std.testing.expect(!@hasField(LayerSlot, "open"));
}

test "layer: outside dismissal covers every mouse button and edge position" {
    var ctx = testCtx();
    defer ctx.deinit();

    const spec: LayerSpec = .{
        .key = .{ .value = 904 },
        .input = .modal,
        .dismiss_on_outside = true,
        .placement = .{ .source = .{ .point = .{ .x = 10, .y = 10 } }, .flip = .none },
    };
    ctx.beginFrameAt(400, 300, 0.0);
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.endFrame();

    const buttons = [_]u8{ 0, 1, 2 };
    const outside_points = [_]Vec2{
        .{ .x = 30, .y = 9 },
        .{ .x = 30, .y = 30 },
        .{ .x = 9, .y = 20 },
        .{ .x = 50, .y = 20 },
        .{ .x = 9, .y = 9 },
        .{ .x = 50, .y = 9 },
        .{ .x = 9, .y = 30 },
        .{ .x = 50, .y = 30 },
    };
    for (buttons) |button| {
        for (outside_points) |point| {
            ctx.pushEvent(.{ .mouse_down = .{
                .x = point.x,
                .y = point.y,
                .button = button,
                .modifiers = 0,
            } });
            ctx.beginFrameAt(400, 300, 0.1);
            try std.testing.expect(ctx.layerDismissed(.{ .value = 904 }));
            ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
            try std.testing.expect(ctx.current_layer_scope.pointer_enabled);
            ctx.endBox();
            ctx.endFrame();
        }
    }
}

test "layer: transient marker slots are reusable" {
    var ctx = testCtx();
    defer ctx.deinit();

    var frame: usize = 0;
    while (frame < 40) : (frame += 1) {
        ctx.beginFrameAt(400, 300, @as(f64, @floatFromInt(frame * 2)) / 10.0);
        (LayerFixture{ .key = @intCast(frame + 100), .box_id = @intCast(frame + 1000), .point = .{ .x = 3, .y = 4 } }).build(&ctx);
        ctx.endFrame();
        try std.testing.expect(ctx.layer_slots_len <= 1);

        ctx.beginFrameAt(400, 300, @as(f64, @floatFromInt(frame * 2 + 1)) / 10.0);
        ctx.endFrame();
        try std.testing.expectEqual(@as(usize, 0), ctx.layer_slots_len);
    }
}

test "tooltip: a one-line tooltip keeps the popup item height and centres its text" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();
    hoverButtonWithTip(&ctx, 1, "Btn", "tip", 0.0);
    hoverButtonWithTip(&ctx, 1, "Btn", "tip", 0.5);

    const bg = tooltipOverlayBgRect(&ctx, "tip").?;
    const pad = ctx.style.spacing.popup_inset;
    const item_h = ctx.style.spacing.popup_item_height;
    // The default bitmap font is shorter than the token, so the token determines this row.
    try std.testing.expectEqual(@as(u32, @intCast(item_h + 2 * pad)), bg.h);

    // And the text sits centred in that row rather than at its top.
    var text_y: ?i32 = null;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .text and std.mem.eql(u8, cmd.text.text, "tip")) text_y = cmd.text.pos.y;
    }
    const row_y = bg.y + pad;
    const ink = font_mod.fontInkHeight(ctx.font);
    _ = ink;
    try std.testing.expect(text_y.? > row_y);
    try std.testing.expect(text_y.? < row_y + item_h);
}

test "popup item: minimum height covers empty short long and CJK labels" {
    const labels = [_][]const u8{ "", "A", "A longer menu item label", "日本語ラベル" };
    const counts = [_]usize{ 1, 4 };

    for (labels) |label| {
        for (counts) |count| {
            var ctx = testCtx();
            defer ctx.deinit();
            var state: popup_mod.PopupState = .{
                .key = .{ .value = 0xD341 },
                .open = true,
                .placement = .{ .source = .{ .point = .{ .x = 10, .y = 10 } }, .flip = .none, .shift = .none },
            };
            var items: [4]popup_mod.PopupItem = undefined;
            for (items[0..count]) |*item| item.* = .{ .label = label };

            ctx.beginFrameAt(320, 200, 0.0);
            _ = popup_mod.popupMenu(&ctx, &state, items[0..count]);
            ctx.endFrame();

            const min_height: u32 = @intCast(ctx.style.spacing.popup_item_height);
            for (0..count) |index| {
                const rect = ctx.getNodeRect(popup_mod.popupItemId(state.key, index)).?;
                try std.testing.expect(rect.h >= min_height);
            }
        }
    }
}

fn expectPopupAndTooltipRowHeight(font: Font, expected_height: i32) !void {
    var menu_ctx = Context.init(std.testing.allocator, font);
    defer menu_ctx.deinit();
    var state: popup_mod.PopupState = .{
        .key = .{ .value = 0xD342 },
        .open = true,
        .placement = .{ .source = .{ .point = .{ .x = 10, .y = 10 } }, .flip = .none, .shift = .none },
    };
    menu_ctx.beginFrameAt(320, 200, 0.0);
    _ = popup_mod.popupMenu(&menu_ctx, &state, &.{.{ .label = "menu" }});
    menu_ctx.endFrame();
    const menu_height = menu_ctx.getNodeRect(popup_mod.popupItemId(state.key, 0)).?.h;

    var tooltip_ctx = Context.init(std.testing.allocator, font);
    defer tooltip_ctx.deinit();
    tooltip_ctx.beginFrameAt(800, 600, 0.0);
    _ = tooltip_ctx.buttonId(1, "Btn", .{});
    tooltip_ctx.endFrame();
    hoverButtonWithTip(&tooltip_ctx, 1, "Btn", "tip", 0.0);
    hoverButtonWithTip(&tooltip_ctx, 1, "Btn", "tip", 0.5);

    const bg = tooltipOverlayBgRect(&tooltip_ctx, "tip").?;
    const pad = tooltip_ctx.style.spacing.popup_inset;
    const tooltip_row_height: u32 = @intCast(@as(i32, @intCast(bg.h)) - 2 * pad);
    try std.testing.expectEqual(@as(u32, @intCast(expected_height)), menu_height);
    try std.testing.expectEqual(menu_height, tooltip_row_height);
}

test "popup item and tooltip: bitmap rows use the 24px token" {
    try expectPopupAndTooltipRowHeight(font_mod.default_font, 24);
}

test "popup item and tooltip: tall rows share the natural font height" {
    try expectPopupAndTooltipRowHeight(tall_tooltip_font, 32);
}

test "layer: a marker takes no part in its parent's size or cursor" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrameAt(400, 300, 0.0);
    ctx.beginBox(.{ .id = 100, .direction = .row, .width = .fit, .height = .fit });
    ctx.beginBox(.{ .id = 101, .width = .{ .fixed = 30 }, .height = .{ .fixed = 10 } });
    ctx.endBox();
    (LayerFixture{ .key = 1, .w = 200, .h = 200, .point = .{ .x = 5, .y = 5 } }).build(&ctx);
    ctx.beginBox(.{ .id = 102, .width = .{ .fixed = 30 }, .height = .{ .fixed = 10 } });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();
    const host = ctx.getNodeRect(100).?;
    // The 200x200 layer is not in the parent's fit measure, and the second flow child sits
    // where it would if the marker were not written at all.
    try std.testing.expectEqual(@as(u32, 60), host.w);
    try std.testing.expectEqual(@as(u32, 10), host.h);
    try std.testing.expectEqual(@as(i32, 30), ctx.getNodeRect(102).?.x);
}

test "layer: an id anchor reads this frame's rect, not the previous one" {
    var ctx = testCtx();
    defer ctx.deinit();
    // Frame 1: the anchor sits at x = 0.
    ctx.beginFrameAt(400, 300, 0.0);
    ctx.beginBox(.{ .id = 200, .direction = .row });
    ctx.beginBox(.{ .id = 201, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    (LayerFixture{ .key = 1, .anchor_id = 201, .box_id = 210 }).build(&ctx);
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(i32, 0), ctx.getNodeRect(210).?.x);

    // Frame 2: a sibling before it moves the anchor to x = 50. A layer reading the previous
    // frame's cache would still place at 0.
    ctx.beginFrameAt(400, 300, 0.1);
    ctx.beginBox(.{ .id = 200, .direction = .row });
    ctx.beginBox(.{ .id = 202, .width = .{ .fixed = 50 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.beginBox(.{ .id = 201, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    (LayerFixture{ .key = 1, .anchor_id = 201, .box_id = 210 }).build(&ctx);
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(i32, 50), ctx.getNodeRect(210).?.x);
    try std.testing.expectEqual(@as(i32, 20), ctx.getNodeRect(210).?.y);
}

test "layer: an anchor that is not in this frame is not drawn at the old place" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrameAt(400, 300, 0.0);
    ctx.beginBox(.{ .id = 300, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    (LayerFixture{ .key = 1, .anchor_id = 300, .box_id = 310 }).build(&ctx);
    ctx.endFrame();
    try std.testing.expect(ctx.getNodeRect(310) != null);

    // The anchor is gone this frame. The layer keeps being built — an application asking for
    // it does not know its anchor vanished — and must simply not appear.
    const before = ctx.postFrameDrawList().cmds.items.len;
    _ = before;
    ctx.beginFrameAt(400, 300, 0.1);
    (LayerFixture{ .key = 1, .anchor_id = 300, .box_id = 310 }).build(&ctx);
    ctx.endFrame();
    try std.testing.expect(ctx.getNodeRect(310) == null);
    try std.testing.expect(ctx.layerPrevRect(.{ .value = 1 }) == null);
}

test "layer: a missing anchor keeps pointer input away from the main tree for one frame" {
    var ctx = testCtx();
    defer ctx.deinit();
    const main_id: Id = 1510;
    const anchor_id: Id = 1511;
    const layer_id: Id = 1512;
    const spec: LayerSpec = .{
        .key = .{ .value = 1513 },
        .input = .modal,
        .placement = .{ .source = .{ .id = anchor_id }, .flip = .none },
    };

    ctx.beginFrameAt(400, 200, 0.0);
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.beginBox(.{ .id = anchor_id, .width = .{ .fixed = 80 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    _ = ctx.buttonId(layer_id, "layer", .{});
    ctx.endBox();
    ctx.endFrame();
    const main_rect = ctx.getNodeRect(main_id).?;

    // The anchor disappears, but the previous placement still owns pointer routing for this
    // synchronization frame. The main button must not see a press at its old coordinates.
    ctx.pushEvent(.{ .mouse_down = .{
        .x = main_rect.x + @as(i32, @intCast(main_rect.w / 2)),
        .y = main_rect.y + @as(i32, @intCast(main_rect.h / 2)),
        .button = 0,
        .modifiers = 0,
    } });
    ctx.beginFrameAt(400, 200, 0.1);
    try std.testing.expect(ctx.wantsMouse());
    const main = ctx.buttonId(main_id, "main", .{});
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    _ = ctx.buttonId(layer_id, "layer", .{});
    ctx.endBox();
    try std.testing.expect(!main.hovered and !main.held and !main.clicked);
    ctx.endFrame();
}

test "layer: a missing anchor drops layer focus and keeps raw Escape available" {
    var ctx = testCtx();
    defer ctx.deinit();
    const main_id: Id = 1520;
    const anchor_id: Id = 1521;
    const layer_id: Id = 1522;
    const spec: LayerSpec = .{
        .key = .{ .value = 1523 },
        .input = .modal,
        .placement = .{ .source = .{ .id = anchor_id }, .flip = .none },
    };

    ctx.beginFrameAt(400, 200, 0.0);
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.beginBox(.{ .id = anchor_id, .width = .{ .fixed = 80 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    _ = ctx.buttonId(layer_id, "layer", .{});
    ctx.endBox();
    ctx.endFrame();
    const layer_rect = ctx.getNodeRect(layer_id).?;

    // Focus the layer while its anchor is present.
    ctx.pushEvent(.{ .mouse_down = .{
        .x = layer_rect.x + @as(i32, @intCast(layer_rect.w / 2)),
        .y = layer_rect.y + @as(i32, @intCast(layer_rect.h / 2)),
        .button = 0,
        .modifiers = 0,
    } });
    ctx.pushEvent(.{ .mouse_up = .{
        .x = layer_rect.x + @as(i32, @intCast(layer_rect.w / 2)),
        .y = layer_rect.y + @as(i32, @intCast(layer_rect.h / 2)),
        .button = 0,
        .modifiers = 0,
    } });
    ctx.beginFrameAt(400, 200, 0.1);
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.beginBox(.{ .id = anchor_id, .width = .{ .fixed = 80 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    _ = ctx.buttonId(layer_id, "layer", .{});
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(layer_id, ctx.focusedId());

    // The route absorbs the main tree even though the current anchor is absent. Focus traversal
    // has no reachable layer geometry, while a layer consumer can still read raw Escape.
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.tab, .modifiers = 0, .repeat = false } });
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.escape, .modifiers = 0, .repeat = false } });
    ctx.beginFrameAt(400, 200, 0.2);
    try std.testing.expect(ctx.wantsKeyboard());
    try std.testing.expect(ctx.input.pressedPlain(input_mod.key.escape, 0, input_mod.mod.all));
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    _ = ctx.buttonId(layer_id, "layer", .{});
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 0), ctx.focusedId());

    // The slot was released at the missing frame's seal. Reappearing is a new context and does
    // not restore the focus that belonged to the missing layer.
    ctx.beginFrameAt(400, 200, 0.3);
    try std.testing.expect(!ctx.wantsKeyboard());
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.beginBox(.{ .id = anchor_id, .width = .{ .fixed = 80 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    _ = ctx.buttonId(layer_id, "layer", .{});
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 0), ctx.focusedId());
}

test "layer: one anchored into another is placed after it, whatever order they registered in" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrameAt(400, 300, 0.0);
    ctx.beginBox(.{ .id = 400, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    // The dependent layer is registered first, so registration order alone would place it
    // before the layer it anchors into.
    (LayerFixture{ .key = 2, .anchor_id = 411, .box_id = 420 }).build(&ctx);
    (LayerFixture{ .key = 1, .anchor_id = 400, .box_id = 411, .w = 30, .h = 15 }).build(&ctx);
    ctx.endFrame();
    const parent_layer = ctx.getNodeRect(411).?;
    const child_layer = ctx.getNodeRect(420).?;
    try std.testing.expectEqual(@as(i32, 0), parent_layer.x);
    try std.testing.expectEqual(@as(i32, 20), parent_layer.y);
    // Below the parent layer's box, which is only knowable once that layer has been placed.
    try std.testing.expectEqual(parent_layer.x, child_layer.x);
    try std.testing.expectEqual(parent_layer.y + @as(i32, @intCast(parent_layer.h)), child_layer.y);
}

fn countSolidRectColor(ctx: *Context, color: Color) usize {
    var count: usize = 0;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd != .rect_filled or cmd.rect_filled.paint != .solid) continue;
        if (std.meta.eql(cmd.rect_filled.paint.solid, color)) count += 1;
    }
    return count;
}

test "layer: nested roots are emitted once in either z order" {
    const cases = [_]struct { outer_z: i32, inner_z: i32 }{
        .{ .outer_z = 10, .inner_z = 1 },
        .{ .outer_z = 1, .inner_z = 10 },
    };
    const outer_color = Color.rgba(0xA1, 0x10, 0x10, 0xFF);
    const inner_color = Color.rgba(0x10, 0xA1, 0x10, 0xFF);

    for (cases) |case| {
        var ctx = testCtx();
        defer ctx.deinit();
        const outer_id: Id = 1501;
        const inner_id: Id = 1502;
        const outer_spec: LayerSpec = .{
            .key = .{ .value = 1503 },
            .z = case.outer_z,
            .placement = .{ .source = .{ .point = .{ .x = 20, .y = 20 } }, .flip = .none, .shift = .none },
        };
        const inner_spec: LayerSpec = .{
            .key = .{ .value = 1504 },
            .z = case.inner_z,
            .placement = .{ .source = .{ .id = outer_id }, .flip = .none, .shift = .none },
        };

        ctx.beginFrameAt(400, 300, 0.0);
        ctx.beginBox(.{
            .layer = &outer_spec,
            .id = outer_id,
            .width = .{ .fixed = 60 },
            .height = .{ .fixed = 30 },
            .bg = outer_color,
        });
        ctx.beginBox(.{
            .layer = &inner_spec,
            .id = inner_id,
            .width = .{ .fixed = 40 },
            .height = .{ .fixed = 20 },
            .bg = inner_color,
        });
        ctx.endBox();
        ctx.endBox();
        ctx.endFrame();

        // The inner marker is a detached root, not an ordinary child of the outer root. One
        // occurrence of each fill therefore proves that neither layout traversal nor layer
        // emission reached the same root twice.
        try std.testing.expectEqual(@as(usize, 1), countSolidRectColor(&ctx, outer_color));
        try std.testing.expectEqual(@as(usize, 1), countSolidRectColor(&ctx, inner_color));
        try std.testing.expectEqual(@as(usize, 2), ctx.layer_owner_map.count());
        try std.testing.expect(ctx.getNodeRect(outer_id) != null);
        try std.testing.expect(ctx.getNodeRect(inner_id) != null);

        var order: [2]u8 = undefined;
        var order_len: usize = 0;
        for (ctx.postFrameDrawList().cmds.items) |cmd| {
            if (cmd != .rect_filled or cmd.rect_filled.paint != .solid) continue;
            const color = cmd.rect_filled.paint.solid;
            const tag: u8 = if (std.meta.eql(color, outer_color)) 1 else if (std.meta.eql(color, inner_color)) 2 else 0;
            if (tag == 0) continue;
            order[order_len] = tag;
            order_len += 1;
        }
        const expected = if (case.outer_z < case.inner_z) [2]u8{ 1, 2 } else [2]u8{ 2, 1 };
        try std.testing.expectEqual(expected, order);
    }
}

test "layer: nested roots are counted once by the layout sanity probe" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.setLayoutSanityEnabled(true);
    const outer_id: Id = 1505;
    const inner_id: Id = 1506;
    const outer: LayerSpec = .{
        .key = .{ .value = 1507 },
        .placement = .{ .source = .{ .point = .{ .x = 20, .y = 20 } }, .flip = .none, .shift = .none },
    };
    const inner: LayerSpec = .{
        .key = .{ .value = 1508 },
        .placement = .{ .source = .{ .id = outer_id }, .flip = .none, .shift = .none },
    };

    ctx.beginFrameAt(400, 300, 0.0);
    ctx.beginBox(.{
        .layer = &outer,
        .id = outer_id,
        .width = .{ .fixed = 60 },
        .height = .{ .fixed = 30 },
    });
    ctx.beginBox(.{
        .layer = &inner,
        .id = inner_id,
        .width = .{ .fixed = 10 },
        .height = .{ .fixed = 10 },
    });
    ctx.beginBox(.{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    // Only the inner root has a child extent larger than its fixed root. An outer traversal
    // reaching the detached inner root too would report the same violation a second time.
    try std.testing.expectEqual(@as(u32, 1), ctx.layout_sanity_result.content_overflow);
}

test "layer: detached roots do not inherit parent clip or scroll in draw commands" {
    var ctx = testCtx();
    defer ctx.deinit();
    const layer_color = Color.rgba(0x10, 0x20, 0xE0, 0xFF);
    const spec: LayerSpec = .{
        .key = .{ .value = 1510 },
        .placement = .{ .source = .{ .point = .{ .x = 100, .y = 100 } }, .flip = .none, .shift = .none },
    };

    ctx.beginFrameAt(400, 300, 0.0);
    ctx.beginBox(.{
        .width = .{ .fixed = 20 },
        .height = .{ .fixed = 20 },
        .clip_children = true,
        .scroll_x = 40,
        .scroll_y = 30,
    });
    ctx.beginBox(.{
        .layer = &spec,
        .width = .{ .fixed = 30 },
        .height = .{ .fixed = 15 },
        .bg = layer_color,
    });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    var found = false;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd != .rect_filled or cmd.rect_filled.paint != .solid) continue;
        if (!std.meta.eql(cmd.rect_filled.paint.solid, layer_color)) continue;
        found = true;
        // This is the layer root's own command clip. The parent's clip and scroll must not
        // cross the detach boundary; the screen root clip remains the active draw clip.
        try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 400, .h = 300 }, cmd.rect_filled.clip);
        try std.testing.expectEqual(Rect{ .x = 100, .y = 100, .w = 30, .h = 15 }, cmd.rect_filled.rect);
    }
    try std.testing.expect(found);
}

fn buildDetachedHitTree(ctx: *Context, marker: *const LayerSpec, main_id: Id, layer_id: Id) ButtonResult {
    ctx.beginBox(.{
        .width = .{ .fixed = 20 },
        .height = .{ .fixed = 20 },
        .clip_children = true,
        .scroll_x = 40,
        .scroll_y = 30,
    });
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.beginBox(.{
        .layer = marker,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 40 },
    });
    const result = ctx.buttonId(layer_id, "layer", .{});
    ctx.endBox();
    ctx.endBox();
    return result;
}

test "layer: detached roots use their own previous-frame clip for hit-test" {
    var ctx = testCtx();
    defer ctx.deinit();
    const marker: LayerSpec = .{
        .key = .{ .value = 1511 },
        .input = .modal,
        .placement = .{ .source = .{ .point = .{ .x = 100, .y = 100 } }, .flip = .none, .shift = .none },
    };
    const main_id: Id = 1512;
    const layer_id: Id = 1513;

    ctx.beginFrameAt(400, 300, 0.0);
    _ = buildDetachedHitTree(&ctx, &marker, main_id, layer_id);
    ctx.endFrame();
    const layer_rect = ctx.getNodeRect(layer_id).?;
    const center = Vec2{
        .x = layer_rect.x + @as(i32, @intCast(layer_rect.w / 2)),
        .y = layer_rect.y + @as(i32, @intCast(layer_rect.h / 2)),
    };
    const layer_cached = ctx.getNodeCachedRect(layer_id).?;
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 400, .h = 300 }, layer_cached.clip);
    try std.testing.expect(pointHitsVisible(layer_cached.rect, layer_cached.clip, center));

    ctx.pushEvent(.{ .mouse_down = .{ .x = center.x, .y = center.y, .button = 0, .modifiers = 0 } });
    ctx.beginFrameAt(400, 300, 0.1);
    const held = buildDetachedHitTree(&ctx, &marker, main_id, layer_id);
    try std.testing.expect(held.held);
    ctx.endFrame();

    ctx.pushEvent(.{ .mouse_up = .{ .x = center.x, .y = center.y, .button = 0, .modifiers = 0 } });
    ctx.beginFrameAt(400, 300, 0.2);
    const clicked = buildDetachedHitTree(&ctx, &marker, main_id, layer_id);
    try std.testing.expect(clicked.clicked);
    ctx.endFrame();
}

test "layer: owner indexing is skipped when a frame has no layer markers" {
    var ctx = testCtx();
    defer ctx.deinit();
    const marker: LayerSpec = .{
        .key = .{ .value = 1514 },
        .placement = .{ .source = .{ .point = .{ .x = 4, .y = 5 } }, .flip = .none, .shift = .none },
    };

    ctx.beginFrameAt(100, 80, 0.0);
    ctx.beginBox(.{ .layer = &marker, .id = 1515, .width = .{ .fixed = 8 }, .height = .{ .fixed = 8 } });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 1), ctx.layer_owner_map.count());

    // The retained table is deliberately left alone here. The early return in placeLayers is
    // the no-marker fast path; the next layer frame clears and rebuilds it before resolving.
    ctx.beginFrameAt(100, 80, 0.1);
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 1), ctx.layer_owner_map.count());
}

test "layer: a missing anchor propagates to the layers anchored into it" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrameAt(400, 300, 0.0);
    // No box 500 anywhere, so layer 1 is missing, and layer 2 anchors into layer 1.
    (LayerFixture{ .key = 1, .anchor_id = 500, .box_id = 511 }).build(&ctx);
    (LayerFixture{ .key = 2, .anchor_id = 511, .box_id = 520 }).build(&ctx);
    ctx.endFrame();
    try std.testing.expect(ctx.getNodeRect(511) == null);
    try std.testing.expect(ctx.getNodeRect(520) == null);
}

test "layer: z decides what covers what, and equal z falls back to registration order" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrameAt(400, 300, 0.0);
    (LayerFixture{ .key = 1, .z = 10, .box_id = 601, .point = .{ .x = 1, .y = 1 } }).build(&ctx);
    (LayerFixture{ .key = 2, .z = 5, .box_id = 602, .point = .{ .x = 2, .y = 2 } }).build(&ctx);
    (LayerFixture{ .key = 3, .z = 5, .box_id = 603, .point = .{ .x = 3, .y = 3 } }).build(&ctx);
    ctx.endFrame();
    for ([_]Id{ 601, 602, 603 }) |id| try std.testing.expect(ctx.getNodeRect(id) != null);
    // Emission walks in this order, so the last one drawn covers the others: the lower z
    // first, and between the two equal z values the one registered first.
    try std.testing.expect(layerBefore(ctx.layers[1], ctx.layers[2]));
    try std.testing.expect(layerBefore(ctx.layers[2], ctx.layers[0]));
    try std.testing.expect(!layerBefore(ctx.layers[0], ctx.layers[1]));
}

test "layer: the slot remembers where a layer was, and that it has gone" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrameAt(400, 300, 0.0);
    (LayerFixture{ .key = 7, .box_id = 700, .point = .{ .x = 11, .y = 13 } }).build(&ctx);
    ctx.endFrame();
    const prev = ctx.layerPrevRect(.{ .value = 7 }).?;
    try std.testing.expectEqual(@as(i32, 11), prev.x);
    try std.testing.expectEqual(@as(i32, 13), prev.y);

    // A frame without it seals and releases the slot, so stale geometry cannot become an
    // input route on the following frame.
    ctx.beginFrameAt(400, 300, 0.1);
    ctx.endFrame();
    try std.testing.expect(ctx.layerPrevRect(.{ .value = 7 }) == null);
}

test "layer: layerWasPlaced follows whether the layer reached the screen" {
    var ctx = testCtx();
    defer ctx.deinit();
    const slot_key: LayerKey = .{ .value = 77 };
    try std.testing.expect(!ctx.layerWasPlaced(slot_key)); // never seen

    ctx.beginFrameAt(400, 300, 0.0);
    (LayerFixture{ .key = 77, .box_id = 7700, .point = .{ .x = 3, .y = 4 } }).build(&ctx);
    ctx.endFrame();
    try std.testing.expect(ctx.layerWasPlaced(slot_key));

    // Built again, but anchored to a box that is not in the frame: it does not reach the
    // screen, and the slot has to say so rather than keep reporting the last time it did.
    ctx.beginFrameAt(400, 300, 0.1);
    (LayerFixture{ .key = 77, .anchor_id = 9999, .box_id = 7700 }).build(&ctx);
    ctx.endFrame();
    try std.testing.expect(!ctx.layerWasPlaced(slot_key));
}

test "layer: a tooltip stays out of the rect cache and the id namespace" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrameAt(400, 300, 0.0);
    // The same explicit id in the main tree and inside a layer that does not cache is not a
    // collision, because the layer's ids are not in the namespace at all.
    ctx.beginBox(.{ .id = 800, .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expect(ctx.getNodeRect(800) != null);
}

test "layer: a marker and the box written after it do not share an auto id" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrameAt(400, 300, 0.0);
    ctx.beginBox(.{ .id = 1000, .direction = .column });
    // The marker is written first, so it takes the ordinal a first child would have. If it
    // did not advance the ordinal, the next box would take the same one — two boxes with one
    // auto id, and one per-id state between them.
    ctx.beginBox(.{
        .layer = &.{ .key = .{ .value = 1 }, .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } } },
        .width = .{ .fixed = 10 },
        .height = .{ .fixed = 10 },
    });
    ctx.endBox();
    const marker_id = ctx.layers[0].root.id;
    ctx.beginBox(.{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    ctx.endBox();
    const sibling_id = ctx.layout_root.?.first_child.?.first_child.?.id;
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expect(marker_id != sibling_id);
}

test "layer: emission puts every layer after the main tree, in z order" {
    var ctx = testCtx();
    defer ctx.deinit();
    const bg_main = Color.rgba(0x11, 0x11, 0x11, 0xFF);
    const bg_low = Color.rgba(0x22, 0x22, 0x22, 0xFF);
    const bg_high = Color.rgba(0x33, 0x33, 0x33, 0xFF);
    ctx.beginFrameAt(400, 300, 0.0);
    ctx.beginBox(.{ .id = 1100, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 }, .bg = bg_main });
    ctx.endBox();
    // Registered high-z first, so registration order alone would emit it first.
    ctx.beginBox(.{
        .layer = &.{ .key = .{ .value = 1 }, .z = 10, .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } } },
        .width = .{ .fixed = 10 },
        .height = .{ .fixed = 10 },
        .bg = bg_high,
    });
    ctx.endBox();
    ctx.beginBox(.{
        .layer = &.{ .key = .{ .value = 2 }, .z = 1, .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } } },
        .width = .{ .fixed = 10 },
        .height = .{ .fixed = 10 },
        .bg = bg_low,
    });
    ctx.endBox();
    ctx.endFrame();

    var order: [3]u8 = .{ 0, 0, 0 };
    var n: usize = 0;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd != .rect_filled) continue;
        if (cmd.rect_filled.paint != .solid) continue;
        const c = cmd.rect_filled.paint.solid;
        const tag: u8 = if (c.r == 0x11) 1 else if (c.r == 0x22) 2 else if (c.r == 0x33) 3 else 0;
        if (tag == 0 or n == order.len) continue;
        order[n] = tag;
        n += 1;
    }
    // main, then z = 1, then z = 10: the draw list itself, not just the comparator.
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, order);
}

test "layer: custom leaves emit into one list in tree then layer order" {
    var ctx = testCtx();
    defer ctx.deinit();

    const Capture = struct {
        color: Color,
        list: ?*DrawList = null,

        fn drawFn(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.list = dl;
            dl.rectFilled(rect, self.color) catch @panic("custom leaf: OOM");
        }
    };
    var main_cap = Capture{ .color = Color.rgba(0x11, 0x11, 0x11, 0xFF) };
    var layer_cap = Capture{ .color = Color.rgba(0x22, 0x22, 0x22, 0xFF) };

    ctx.beginFrameAt(400, 300, 0.0);
    ctx.beginBox(.{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    ctx.custom(.{ .x = 40, .y = 20 }, Capture.drawFn, &main_cap);
    ctx.endBox();
    ctx.beginBox(.{
        .layer = &.{ .key = .{ .value = 1 }, .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } } },
        .width = .{ .fixed = 40 },
        .height = .{ .fixed = 20 },
    });
    ctx.custom(.{ .x = 40, .y = 20 }, Capture.drawFn, &layer_cap);
    ctx.endBox();
    ctx.endFrame();

    const cmds = ctx.postFrameDrawList().cmds.items;
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqual(main_cap.color, cmds[0].rect_filled.paint.solid);
    try std.testing.expectEqual(layer_cap.color, cmds[1].rect_filled.paint.solid);
    try std.testing.expectEqual(@intFromPtr(main_cap.list.?), @intFromPtr(layer_cap.list.?));
    try std.testing.expectEqual(@intFromPtr(main_cap.list.?), @intFromPtr(ctx.postFrameDrawList()));
}

test "layer: a root sizes against the boundary, not against a parent it does not have" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrameAt(400, 300, 0.0);
    ctx.beginBox(.{
        .layer = &.{ .key = .{ .value = 1 }, .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } }, .flip = .none } },
        .id = 1200,
        .width = .{ .percent = 0.25 },
        .height = .{ .fixed = 30 },
    });
    ctx.endBox();
    ctx.endFrame();
    const r = ctx.getNodeRect(1200).?;
    try std.testing.expectEqual(@as(u32, 100), r.w); // a quarter of the 400-wide boundary
    try std.testing.expectEqual(@as(u32, 30), r.h);
}

test "layer: a modal marker owns shared widget input" {
    var ctx = testCtx();
    defer ctx.deinit();

    const main_id: Id = 1301;
    const layer_id: Id = 1302;
    const spec: LayerSpec = .{
        .key = .{ .value = 1303 },
        .input = .modal,
        .placement = .{ .source = .{ .point = .{ .x = 100, .y = 40 } }, .flip = .none },
    };

    // First-visible frame: the marker is drawable but has no previous geometry, so neither
    // button can acquire input from it.
    ctx.beginFrameAt(400, 300, 0.0);
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.beginBox(.{
        .layer = &spec,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 40 },
    });
    _ = ctx.buttonId(layer_id, "layer", .{});
    ctx.endBox();
    ctx.endFrame();

    const layer_rect = ctx.getNodeRect(layer_id).?;

    // The main tree is built first, but the previous-frame modal marker owns the press.
    ctx.pushEvent(.{ .mouse_down = .{
        .x = layer_rect.x + @as(i32, @intCast(layer_rect.w / 2)),
        .y = layer_rect.y + @as(i32, @intCast(layer_rect.h / 2)),
        .button = 0,
        .modifiers = 0,
    } });
    ctx.beginFrameAt(400, 300, 0.1);
    const main_first = ctx.buttonId(main_id, "main", .{});
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    const layer_first = ctx.buttonId(layer_id, "layer", .{});
    ctx.endBox();
    try std.testing.expect(!main_first.hovered and !main_first.held and !main_first.clicked);
    try std.testing.expect(layer_first.held);
    try std.testing.expectEqual(layer_id, ctx.focusedId());
    try std.testing.expectEqual(@as(usize, 2), ctx.focus_order.items.len);
    try std.testing.expect(!ctx.focus_scope_order.items[0].enabled);
    try std.testing.expect(ctx.focus_scope_order.items[1].enabled);
    ctx.endFrame();

    // Reverse build order: releasing in the layer still cannot activate the main button.
    ctx.pushEvent(.{ .mouse_up = .{ .x = layer_rect.x, .y = layer_rect.y, .button = 0, .modifiers = 0 } });
    ctx.beginFrameAt(400, 300, 0.2);
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    const layer_second = ctx.buttonId(layer_id, "layer", .{});
    ctx.endBox();
    const main_second = ctx.buttonId(main_id, "main", .{});
    try std.testing.expect(layer_second.clicked);
    try std.testing.expect(!main_second.clicked);
    ctx.endFrame();
}

test "layer: generic input gates are stable before, inside, after, and outside a marker" {
    var ctx = testCtx();
    defer ctx.deinit();
    const spec: LayerSpec = .{
        .key = .{ .value = 1310 },
        .input = .modal,
        .placement = .{ .source = .{ .point = .{ .x = 100, .y = 40 } }, .flip = .none },
    };

    ctx.beginFrameAt(400, 300, 0.0);
    try std.testing.expect(!ctx.wantsMouse());
    try std.testing.expect(!ctx.wantsKeyboard());
    try std.testing.expect(!ctx.wantsTextInput());
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    try std.testing.expect(!ctx.wantsMouse());
    try std.testing.expect(!ctx.wantsKeyboard());
    try std.testing.expect(!ctx.wantsTextInput());
    ctx.endBox();
    try std.testing.expect(!ctx.wantsMouse());
    try std.testing.expect(!ctx.wantsKeyboard());
    try std.testing.expect(!ctx.wantsTextInput());
    ctx.endFrame();
    try std.testing.expect(!ctx.wantsMouse());
    try std.testing.expect(!ctx.wantsKeyboard());
    try std.testing.expect(!ctx.wantsTextInput());

    ctx.beginFrameAt(400, 300, 0.1);
    try std.testing.expect(ctx.wantsMouse());
    try std.testing.expect(ctx.wantsKeyboard());
    try std.testing.expect(!ctx.wantsTextInput());
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    try std.testing.expect(ctx.wantsMouse());
    try std.testing.expect(ctx.wantsKeyboard());
    try std.testing.expect(!ctx.wantsTextInput());
    ctx.endBox();
    try std.testing.expect(ctx.wantsMouse());
    try std.testing.expect(ctx.wantsKeyboard());
    try std.testing.expect(!ctx.wantsTextInput());
    ctx.endFrame();
    try std.testing.expect(ctx.wantsMouse());
    try std.testing.expect(ctx.wantsKeyboard());
    try std.testing.expect(!ctx.wantsTextInput());
}

test "layer: none markers never request mouse input" {
    var ctx = testCtx();
    defer ctx.deinit();
    const spec: LayerSpec = .{
        .key = .{ .value = 1320 },
        .input = .none,
        .placement = .{ .source = .{ .point = .{ .x = 20, .y = 20 } }, .flip = .none },
    };

    ctx.beginFrameAt(200, 100, 0.0);
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    try std.testing.expect(!ctx.current_layer_scope.pointer_enabled);
    try std.testing.expect(!ctx.wantsMouse());
    ctx.endBox();
    ctx.endFrame();

    ctx.beginFrameAt(200, 100, 0.1);
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    try std.testing.expect(!ctx.current_layer_scope.pointer_enabled);
    try std.testing.expect(!ctx.wantsMouse());
    ctx.endBox();
    ctx.endFrame();
}

test "layer: main focus is restored after a modal route is released" {
    var ctx = testCtx();
    defer ctx.deinit();
    const main_id: Id = 1331;
    const layer_id: Id = 1332;
    const spec: LayerSpec = .{
        .key = .{ .value = 1333 },
        .input = .modal,
        .placement = .{ .source = .{ .point = .{ .x = 100, .y = 40 } }, .flip = .none },
    };

    ctx.beginFrameAt(400, 200, 0.0);
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.endFrame();
    const main_rect = ctx.getNodeRect(main_id).?;

    ctx.beginFrameAt(400, 200, 0.1);
    const main_center = .{
        .x = main_rect.x + @as(i32, @intCast(main_rect.w / 2)),
        .y = main_rect.y + @as(i32, @intCast(main_rect.h / 2)),
    };
    ctx.pushEvent(.{ .mouse_down = .{ .x = main_center.x, .y = main_center.y, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_up = .{ .x = main_center.x, .y = main_center.y, .button = 0, .modifiers = 0 } });
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.endFrame();
    try std.testing.expectEqual(main_id, ctx.focusedId());

    // The first visible frame has no route yet, so main keeps its focus while the layer draws.
    ctx.beginFrameAt(400, 200, 0.2);
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 140 }, .height = .{ .fixed = 32 } });
    ctx.endBox();
    ctx.endFrame();

    // On the next frame the prior placement latches the modal route. Tab can now select only
    // the modal child; its focus is later restored to the saved main id.
    ctx.beginFrameAt(400, 200, 0.3);
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 140 }, .height = .{ .fixed = 32 } });
    _ = ctx.buttonId(layer_id, "layer", .{});
    ctx.endBox();
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.tab, .modifiers = 0, .repeat = false } });
    ctx.endFrame();
    try std.testing.expectEqual(layer_id, ctx.focusedId());

    // Reverse traversal must stay inside the modal scope as well: a main entry is still in the
    // submission order for restoration, but it is not a candidate while the route is active.
    ctx.beginFrameAt(400, 200, 0.35);
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 140 }, .height = .{ .fixed = 32 } });
    _ = ctx.buttonId(layer_id, "layer", .{});
    ctx.endBox();
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.tab, .modifiers = input_mod.mod.shift, .repeat = false } });
    ctx.endFrame();
    try std.testing.expectEqual(layer_id, ctx.focusedId());

    // The omitted marker is still absorbed by the previous-frame route, then its slot is freed.
    ctx.beginFrameAt(400, 200, 0.4);
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.endFrame();
    try std.testing.expectEqual(layer_id, ctx.focusedId());

    ctx.beginFrameAt(400, 200, 0.5);
    try std.testing.expectEqual(main_id, ctx.focusedId());
    _ = ctx.buttonId(main_id, "main", .{});
    ctx.endFrame();
}

test "layer: root order takes precedence over scroll depth and serial" {
    const records = [_]ScrollAreaRecord{
        .{ .id = 1401, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .root_order = 0, .depth = 9, .serial = 9 },
        .{ .id = 1402, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .root_order = 1, .depth = 0, .serial = 1 },
        .{ .id = 1403, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .root_order = 1, .depth = 2, .serial = 0 },
        .{ .id = 1404, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .root_order = 1, .depth = 2, .serial = 3 },
    };
    try std.testing.expectEqual(@as(Id, 1404), pickWheelChainHead(&records, .{ .x = 50, .y = 50 }));
}

test "layer: a frame with neither a layout tree nor a layer leaves the draw list alone" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrameAt(400, 300, 0.0);
    const dl = ctx.mainDrawList();
    dl.rectFilled(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, Color.rgba(1, 2, 3, 4)) catch unreachable;
    const n = dl.cmds.items.len;
    ctx.endFrame();
    // The manual DrawList path is untouched: no layout, no cache update, no emit.
    try std.testing.expectEqual(n, ctx.postFrameDrawList().cmds.items.len);
}

test "layer: a frame with no main tree but a layer still places and draws it" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrameAt(400, 300, 0.0);
    (LayerFixture{ .key = 9, .box_id = 900, .point = .{ .x = 7, .y = 9 } }).build(&ctx);
    ctx.endFrame();
    const r = ctx.getNodeRect(900).?;
    try std.testing.expectEqual(@as(i32, 7), r.x);
    try std.testing.expectEqual(@as(i32, 9), r.y);
}

test "tooltip: the overlay is emitted after the ordinary UI, so it draws on top" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();
    const before_tip_len = blk: {
        hoverButtonWithTip(&ctx, 1, "Btn", "tail tip", 0.0);
        break :blk ctx.postFrameDrawList().cmds.items.len;
    };
    hoverButtonWithTip(&ctx, 1, "Btn", "tail tip", 0.5);
    const cmds = ctx.postFrameDrawList().cmds.items;
    try std.testing.expect(cmds.len > before_tip_len);
    // The tooltip is a layer, so it emits a background, its content and a border. What the
    // ordering has to guarantee is that all of it lands after the frame's ordinary UI —
    // asserted as "no text is emitted after the tooltip's", which holds whichever of the
    // three commands happens to be last.
    var tip_index: ?usize = null;
    for (cmds, 0..) |cmd, i| {
        if (cmd != .text) continue;
        if (std.mem.eql(u8, cmd.text.text, "tail tip")) {
            tip_index = i;
        } else {
            try std.testing.expect(tip_index == null);
        }
    }
    try std.testing.expect(tip_index != null);
}

test "tooltip: overlay clears on the next frame after leave" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();

    hoverButtonWithTip(&ctx, 1, "Btn", "gone", 0.0);
    hoverButtonWithTip(&ctx, 1, "Btn", "gone", 0.5);
    try std.testing.expect(tooltipHasText(&ctx, "gone"));

    // leave: move outside
    ctx.beginFrameAt(800, 600, 0.6);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 700, .y = 500, .modifiers = 0 } });
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.tooltip("gone");
    ctx.endFrame();
    try std.testing.expect(!tooltipHasText(&ctx, "gone"));
}

test "tooltip: at screen edges, outer is clamped inside the screen" {
    var ctx = testCtx();
    defer ctx.deinit();
    const tip = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"; // Long text to force right-edge clamp

    // Place the button near the bottom-right
    ctx.beginFrameAt(200, 80, 0.0);
    ctx.beginBox(.{ .direction = .column });
    ctx.beginBox(.{ .height = .{ .fixed = 50 }, .width = .{ .fixed = 150 } });
    ctx.endBox();
    ctx.beginBox(.{ .direction = .row });
    ctx.beginBox(.{ .width = .{ .fixed = 150 } });
    ctx.endBox();
    _ = ctx.buttonId(1, "E", .{});
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    const r = ctx.getNodeRect(1).?;
    const cx = r.x + @as(i32, @intCast(r.w / 2));
    const cy = r.y + @as(i32, @intCast(r.h / 2));

    ctx.beginFrameAt(200, 80, 0.0);
    ctx.pushEvent(.{ .mouse_move = .{ .x = cx, .y = cy, .modifiers = 0 } });
    ctx.beginBox(.{ .direction = .column });
    ctx.beginBox(.{ .height = .{ .fixed = 50 }, .width = .{ .fixed = 150 } });
    ctx.endBox();
    ctx.beginBox(.{ .direction = .row });
    ctx.beginBox(.{ .width = .{ .fixed = 150 } });
    ctx.endBox();
    _ = ctx.buttonId(1, "E", .{});
    ctx.tooltip(tip);
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    ctx.beginFrameAt(200, 80, 0.5);
    ctx.pushEvent(.{ .mouse_move = .{ .x = cx, .y = cy, .modifiers = 0 } });
    ctx.beginBox(.{ .direction = .column });
    ctx.beginBox(.{ .height = .{ .fixed = 50 }, .width = .{ .fixed = 150 } });
    ctx.endBox();
    ctx.beginBox(.{ .direction = .row });
    ctx.beginBox(.{ .width = .{ .fixed = 150 } });
    ctx.endBox();
    _ = ctx.buttonId(1, "E", .{});
    ctx.tooltip(tip);
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    const bg = tooltipOverlayBgRect(&ctx, tip).?;
    try std.testing.expect(bg.x >= 0);
    try std.testing.expect(bg.y >= 0);
    try std.testing.expect(@as(i64, bg.x) + bg.w <= 200);
    try std.testing.expect(@as(i64, bg.y) + bg.h <= 80);
}

test "tooltip: re-hover after leave does not inherit the timer" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();

    hoverButtonWithTip(&ctx, 1, "Btn", "re", 0.0);
    hoverButtonWithTip(&ctx, 1, "Btn", "re", 0.5);
    try std.testing.expect(tooltipHasText(&ctx, "re"));

    // leave
    ctx.beginFrameAt(800, 600, 1.0);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 700, .y = 500, .modifiers = 0 } });
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.tooltip("re");
    ctx.endFrame();
    try std.testing.expect(!tooltipHasText(&ctx, "re"));

    // Re-hover: not shown immediately; still hidden below the delay
    hoverButtonWithTip(&ctx, 1, "Btn", "re", 1.0);
    try std.testing.expect(!tooltipHasText(&ctx, "re"));
    hoverButtonWithTip(&ctx, 1, "Btn", "re", 1.4);
    try std.testing.expect(!tooltipHasText(&ctx, "re"));
    hoverButtonWithTip(&ctx, 1, "Btn", "re", 1.5);
    try std.testing.expect(tooltipHasText(&ctx, "re"));
}

test "tooltip: if not built this frame, no stale overlay appears" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();

    hoverButtonWithTip(&ctx, 1, "Btn", "stale", 0.0);
    hoverButtonWithTip(&ctx, 1, "Btn", "stale", 0.5);
    try std.testing.expect(tooltipHasText(&ctx, "stale"));

    // Empty frame without building the target widget
    ctx.beginFrameAt(800, 600, 0.6);
    ctx.beginBox(.{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expect(!tooltipHasText(&ctx, "stale"));
    try std.testing.expectEqual(@as(Id, 0), ctx.tooltip_hover_id);
}

fn simpleBoxTip(_: *anyopaque, c: *Context) void {
    c.label("box tip");
}

const CountingTip = struct {
    calls: u32 = 0,
    fn build(ptr: *anyopaque, c: *Context) void {
        const self: *CountingTip = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        c.label("counted tip");
    }
};

const ExplicitIdTip = struct {
    const box_id: Id = 0xC0FFEE;
    fn build(_: *anyopaque, c: *Context) void {
        c.beginBox(.{ .id = box_id, .width = .{ .fixed = 40 }, .height = .{ .fixed = 16 } });
        c.label("id tip");
        c.endBox();
    }
};

fn hoverButtonWithBox(ctx: *Context, id: Id, label: []const u8, build_fn: TooltipBuildFn, build_ctx: *anyopaque, now_s: f64) void {
    ctx.beginFrameAt(800, 600, now_s);
    const r = ctx.getNodeRect(id) orelse Rect{ .x = 0, .y = 0, .w = 48, .h = 24 };
    const cx = r.x + @as(i32, @intCast(r.w / 2));
    const cy = r.y + @as(i32, @intCast(r.h / 2));
    ctx.pushEvent(.{ .mouse_move = .{ .x = cx, .y = cy, .modifiers = 0 } });
    _ = ctx.buttonId(id, label, .{});
    ctx.tooltipBox(build_fn, build_ctx);
    ctx.endFrame();
}

test "tooltipBox: hidden on the first hover frame and before the delay" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();

    hoverButtonWithBox(&ctx, 1, "Btn", simpleBoxTip, &dummy, 0.0);
    try std.testing.expect(!tooltipHasText(&ctx, "box tip"));
    try std.testing.expectEqual(@as(u32, 0), ctx.tooltip_builder_calls);

    hoverButtonWithBox(&ctx, 1, "Btn", simpleBoxTip, &dummy, 0.4);
    try std.testing.expect(!tooltipHasText(&ctx, "box tip"));
    try std.testing.expectEqual(@as(u32, 0), ctx.tooltip_builder_calls);
}

test "tooltipBox: shows after 500ms hover and hides on leave" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();

    hoverButtonWithBox(&ctx, 1, "Btn", simpleBoxTip, &dummy, 0.0);
    hoverButtonWithBox(&ctx, 1, "Btn", simpleBoxTip, &dummy, 0.5);
    try std.testing.expect(tooltipHasText(&ctx, "box tip"));
    try std.testing.expectEqual(@as(u32, 1), ctx.tooltip_builder_calls);
    try std.testing.expectEqual(@as(u32, 1), ctx.tooltip_layout_calls);

    ctx.beginFrameAt(800, 600, 0.6);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 700, .y = 500, .modifiers = 0 } });
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.tooltipBox(simpleBoxTip, &dummy);
    ctx.endFrame();
    try std.testing.expect(!tooltipHasText(&ctx, "box tip"));
    try std.testing.expectEqual(@as(u32, 0), ctx.tooltip_builder_calls);
}

test "tooltipBox: builder is not called until the delay fires" {
    var ctx = testCtx();
    defer ctx.deinit();
    var counter = CountingTip{};

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();

    hoverButtonWithBox(&ctx, 1, "Btn", CountingTip.build, &counter, 0.0);
    try std.testing.expectEqual(@as(u32, 0), counter.calls);
    hoverButtonWithBox(&ctx, 1, "Btn", CountingTip.build, &counter, 0.4);
    try std.testing.expectEqual(@as(u32, 0), counter.calls);
    hoverButtonWithBox(&ctx, 1, "Btn", CountingTip.build, &counter, 0.5);
    try std.testing.expectEqual(@as(u32, 1), counter.calls);
}

test "tooltipBox: subtree does not join the main layout, rect cache, or focus order" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();

    hoverButtonWithBox(&ctx, 1, "Btn", ExplicitIdTip.build, &dummy, 0.0);
    const child_count_hidden = ctx.layout_root.?.child_count;
    const first_rect_hidden = ctx.layout_root.?.first_child.?.rect;
    const cache_len_hidden = ctx.rect_cache.count();
    const focus_len_hidden = ctx.focus_order.items.len;

    hoverButtonWithBox(&ctx, 1, "Btn", ExplicitIdTip.build, &dummy, 0.5);
    try std.testing.expect(tooltipHasText(&ctx, "id tip"));
    try std.testing.expectEqual(child_count_hidden, ctx.layout_root.?.child_count);
    try std.testing.expectEqual(first_rect_hidden, ctx.layout_root.?.first_child.?.rect);
    try std.testing.expectEqual(cache_len_hidden, ctx.rect_cache.count());
    try std.testing.expectEqual(focus_len_hidden, ctx.focus_order.items.len);
    try std.testing.expect(ctx.getNodeRect(ExplicitIdTip.box_id) == null);
    try std.testing.expect(ctx.rect_cache.get(ExplicitIdTip.box_id) == null);
    for (ctx.focus_order.items) |fid| {
        try std.testing.expect(fid != ExplicitIdTip.box_id);
    }
}

test "tooltipBox then tooltip in the same frame: text wins" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();

    hoverButtonWithTip(&ctx, 1, "Btn", "text wins", 0.0);

    ctx.beginFrameAt(800, 600, 0.5);
    const r = ctx.getNodeRect(1).?;
    ctx.pushEvent(.{ .mouse_move = .{
        .x = r.x + @as(i32, @intCast(r.w / 2)),
        .y = r.y + @as(i32, @intCast(r.h / 2)),
        .modifiers = 0,
    } });
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.tooltipBox(simpleBoxTip, &dummy);
    ctx.tooltip("text wins");
    ctx.endFrame();

    try std.testing.expect(tooltipHasText(&ctx, "text wins"));
    try std.testing.expect(!tooltipHasText(&ctx, "box tip"));
}

test "tooltip then tooltipBox in the same frame: custom wins" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();

    hoverButtonWithTip(&ctx, 1, "Btn", "text lost", 0.0);

    ctx.beginFrameAt(800, 600, 0.5);
    const r = ctx.getNodeRect(1).?;
    ctx.pushEvent(.{ .mouse_move = .{
        .x = r.x + @as(i32, @intCast(r.w / 2)),
        .y = r.y + @as(i32, @intCast(r.h / 2)),
        .modifiers = 0,
    } });
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.tooltip("text lost");
    ctx.tooltipBox(simpleBoxTip, &dummy);
    ctx.endFrame();

    try std.testing.expect(tooltipHasText(&ctx, "box tip"));
    try std.testing.expect(!tooltipHasText(&ctx, "text lost"));
}

test "tooltipBox: image pixels from the frame arena survive emit" {
    var ctx = testCtx();
    defer ctx.deinit();

    const ImageTip = struct {
        fn build(_: *anyopaque, c: *Context) void {
            const src = [_]u32{ 0xFF112233, 0xFF445566, 0xFF778899, 0xFFAABBCC };
            const copy = c.dupePixels(&src);
            c.imageBox(0xBEEF, copy, 2, 2, .{});
        }
    };

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();

    var dummy: u8 = 0;
    hoverButtonWithBox(&ctx, 1, "Btn", ImageTip.build, &dummy, 0.0);
    hoverButtonWithBox(&ctx, 1, "Btn", ImageTip.build, &dummy, 0.5);

    var saw_image = false;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .image) {
            saw_image = true;
            try std.testing.expectEqual(@as(u32, 2), cmd.image.src_w);
            try std.testing.expectEqual(@as(u32, 2), cmd.image.src_h);
            try std.testing.expectEqual(@as(u32, 0xFF112233), cmd.image.pixels[0]);
        }
    }
    try std.testing.expect(saw_image);
}

test "tooltipBox: custom leaf emits at the tooltip layer position" {
    var ctx = testCtx();
    defer ctx.deinit();

    const CustomTip = struct {
        color: Color,
        list: ?*DrawList = null,

        fn build(ptr: *anyopaque, c: *Context) void {
            c.beginBox(.{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
            c.custom(.{ .x = 40, .y = 20 }, @This().draw, ptr);
            c.endBox();
        }

        fn draw(ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.list = dl;
            dl.rectFilled(rect, self.color) catch @panic("tooltip custom leaf: OOM");
        }
    };
    const main_color = Color.rgba(0x11, 0x11, 0x11, 0xFF);
    const tooltip_color = Color.rgba(0x22, 0x22, 0x22, 0xFF);
    const post_color = Color.rgba(0x33, 0x33, 0x33, 0xFF);
    var tip = CustomTip{ .color = tooltip_color };

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();
    hoverButtonWithBox(&ctx, 1, "Btn", CustomTip.build, &tip, 0.0);

    ctx.beginFrameAt(800, 600, 0.5);
    const r = ctx.getNodeRect(1).?;
    ctx.pushEvent(.{ .mouse_move = .{
        .x = r.x + @as(i32, @intCast(r.w / 2)),
        .y = r.y + @as(i32, @intCast(r.h / 2)),
        .modifiers = 0,
    } });
    try ctx.mainDrawList().rectFilled(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, main_color);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.tooltipBox(CustomTip.build, &tip);
    ctx.endFrame();
    try ctx.postFrameDrawList().rectFilled(.{ .x = 4, .y = 0, .w = 4, .h = 4 }, post_color);

    var main_index: ?usize = null;
    var tooltip_index: ?usize = null;
    var post_index: ?usize = null;
    for (ctx.postFrameDrawList().cmds.items, 0..) |cmd, i| {
        if (cmd != .rect_filled or cmd.rect_filled.paint != .solid) continue;
        const color = cmd.rect_filled.paint.solid;
        if (std.meta.eql(color, main_color)) main_index = i;
        if (std.meta.eql(color, tooltip_color)) tooltip_index = i;
        if (std.meta.eql(color, post_color)) post_index = i;
    }
    try std.testing.expectEqual(@intFromPtr(ctx.postFrameDrawList()), @intFromPtr(tip.list.?));
    try std.testing.expect(main_index.? < tooltip_index.?);
    try std.testing.expect(tooltip_index.? < post_index.?);
}

// ── Keyboard focus traversal ──

const key = input_mod.key;
const mod_bits = input_mod.mod;

fn tabEvent(ctx: *Context, modifiers: u32) void {
    ctx.pushEvent(.{ .key_down = .{ .code = key.tab, .modifiers = modifiers, .repeat = false } });
}

/// Submit `ids` as a row of focusable boxes of the given size and end the frame.
fn focusFrame(ctx: *Context, ids: []const Id, w: i32, h: i32) void {
    for (ids) |id| {
        ctx.registerFocusable(id);
        ctx.beginBox(.{ .id = id, .width = .{ .fixed = w }, .height = .{ .fixed = h } });
        ctx.endBox();
    }
}

test "focus traversal: Tab walks submission order forward and Shift+Tab back, wrapping at both ends" {
    var ctx = testCtx();
    defer ctx.deinit();
    const ids = [_]Id{ 1, 2, 3 };

    // Frame 1 only registers the order; nothing is focused yet, so Tab starts at the first entry.
    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 1), ctx.state.focused_id);
    try std.testing.expect(ctx.state.focus_visible);

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 2), ctx.state.focused_id);

    // Forward off the end wraps to the front.
    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 3), ctx.state.focused_id);
    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 1), ctx.state.focused_id);

    // Backward off the front wraps to the end.
    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    tabEvent(&ctx, mod_bits.shift);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 3), ctx.state.focused_id);
}

test "focus traversal: Shift is read from the Tab event, not from the last event of the frame" {
    var ctx = testCtx();
    defer ctx.deinit();
    const ids = [_]Id{ 1, 2, 3 };

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 1), ctx.state.focused_id);

    // Shift+Tab arrives first, an unmodified key after it. Reading the frame's trailing modifier
    // state would lose the Shift and step forward instead of back.
    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    tabEvent(&ctx, mod_bits.shift);
    ctx.pushEvent(.{ .key_down = .{ .code = 'A', .modifiers = 0, .repeat = false } });
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 3), ctx.state.focused_id);
}

test "focus traversal: auto-repeat and modified Tab do not move the focus" {
    var ctx = testCtx();
    defer ctx.deinit();
    const ids = [_]Id{ 1, 2 };

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    ctx.pushEvent(.{ .key_down = .{ .code = key.tab, .modifiers = 0, .repeat = true } });
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 0), ctx.state.focused_id);

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    tabEvent(&ctx, mod_bits.cmd);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 0), ctx.state.focused_id);
}

test "focus traversal: a widget that stops being submitted leaves the order" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{ 1, 2, 3 }, 40, 20);
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 1), ctx.state.focused_id);

    // 2 is gone this frame, so Tab from 1 lands on 3.
    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{ 1, 3 }, 40, 20);
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 3), ctx.state.focused_id);
}

test "focus traversal: a submitted widget laid out to nothing is skipped" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.registerFocusable(1);
    ctx.beginBox(.{ .id = 1, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    // Submitted, focusable, and zero-size: invisible to the user, so invisible to Tab.
    ctx.registerFocusable(2);
    ctx.beginBox(.{ .id = 2, .width = .{ .fixed = 0 }, .height = .{ .fixed = 0 } });
    ctx.endBox();
    ctx.registerFocusable(3);
    ctx.beginBox(.{ .id = 3, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 1), ctx.state.focused_id);

    ctx.beginFrame(800, 600);
    ctx.registerFocusable(1);
    ctx.beginBox(.{ .id = 1, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.registerFocusable(2);
    ctx.beginBox(.{ .id = 2, .width = .{ .fixed = 0 }, .height = .{ .fixed = 0 } });
    ctx.endBox();
    ctx.registerFocusable(3);
    ctx.beginBox(.{ .id = 3, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 3), ctx.state.focused_id);
}

test "focus traversal: with nothing reachable the focus stays put and an outside click still clears it" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{1}, 40, 20);
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 1), ctx.state.focused_id);

    // Only a zero-size candidate is left. The move must not happen, and must not mark the frame as
    // having claimed focus — otherwise the click below would be swallowed.
    ctx.beginFrame(800, 600);
    ctx.registerFocusable(2);
    ctx.beginBox(.{ .id = 2, .width = .{ .fixed = 0 }, .height = .{ .fixed = 0 } });
    ctx.endBox();
    tabEvent(&ctx, 0);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 700, .y = 500, .button = 0, .modifiers = 0 } });
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 0), ctx.state.focused_id);
    try std.testing.expect(!ctx.state.focus_visible);
}

test "focus traversal: a pointer press in the same frame beats a pending Tab" {
    var ctx = testCtx();
    defer ctx.deinit();
    const ids = [_]Id{ 1, 2, 3 };

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 1), ctx.state.focused_id);

    // Tab plus a click that claims focus elsewhere: the click wins and the ring stays off.
    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    tabEvent(&ctx, 0);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } });
    _ = ctx.claimFocus(3);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 3), ctx.state.focused_id);
    try std.testing.expect(!ctx.state.focus_visible);

    // Tab plus a click that claims nothing: the click drops the focus rather than the Tab moving it.
    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    tabEvent(&ctx, 0);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 700, .y = 500, .button = 0, .modifiers = 0 } });
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 0), ctx.state.focused_id);
}

test "focus traversal: claimFocus focuses without raising the ring" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{ 1, 2 }, 40, 20);
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expect(ctx.isFocusVisible(1));

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{ 1, 2 }, 40, 20);
    _ = ctx.claimFocus(2);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 2), ctx.state.focused_id);
    try std.testing.expect(!ctx.isFocusVisible(2));
}

test "focus traversal: a modal layer takes ownership of the order" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{ 1, 2 }, 40, 20);
    ctx.endFrame();

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{ 1, 2 }, 40, 20);
    const spec: LayerSpec = .{
        .key = .{ .value = 99 },
        .input = .modal,
        .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } }, .flip = .none },
    };
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 80 }, .height = .{ .fixed = 20 } });
    ctx.registerFocusable(3);
    ctx.beginBox(.{ .id = 3, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{ 1, 2 }, 40, 20);
    ctx.beginBox(.{ .layer = &spec, .width = .{ .fixed = 80 }, .height = .{ .fixed = 20 } });
    ctx.registerFocusable(3);
    ctx.beginBox(.{ .id = 3, .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.endBox();
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 3), ctx.focus_order.items.len);
    try std.testing.expectEqual(@as(Id, 3), ctx.state.focused_id);
}

test "focus traversal: focus_order does not reallocate once the interface has settled" {
    var ctx = testCtx();
    defer ctx.deinit();
    const ids = [_]Id{ 1, 2, 3, 4, 5, 6, 7, 8 };

    // Warm up: the first frames grow the list to its working size.
    for (0..3) |_| {
        ctx.beginFrame(800, 600);
        focusFrame(&ctx, &ids, 40, 20);
        ctx.endFrame();
    }
    const settled = ctx.focus_order.capacity;
    try std.testing.expect(settled >= ids.len);

    for (0..20) |_| {
        ctx.beginFrame(800, 600);
        focusFrame(&ctx, &ids, 40, 20);
        ctx.endFrame();
        try std.testing.expectEqual(settled, ctx.focus_order.capacity);
    }
}

test "focus traversal: a Tab during a drag does not pull the focus off the dragged widget" {
    var ctx = testCtx();
    defer ctx.deinit();
    const ids = [_]Id{ 1, 2, 3 };

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    ctx.pushEvent(.{ .mouse_down = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } });
    _ = ctx.claimFocus(1);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 1), ctx.state.focused_id);

    // Second frame of the drag: the button is still down, no fresh press. Tab must not move the
    // focus out from under a widget the pointer is holding.
    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    tabEvent(&ctx, 0);
    _ = ctx.claimFocus(1);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 1), ctx.state.focused_id);

    // Released: Tab works again.
    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &ids, 40, 20);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 5, .y = 5, .button = 0, .modifiers = 0 } });
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 2), ctx.state.focused_id);
}

test "focus traversal: with the focus outside the order, next takes the first and prev the last" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{ 1, 2, 3 }, 40, 20);
    _ = ctx.claimFocus(99); // never submitted
    ctx.endFrame();

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{ 1, 2, 3 }, 40, 20);
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 1), ctx.state.focused_id);

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{ 1, 2, 3 }, 40, 20);
    _ = ctx.claimFocus(99);
    ctx.endFrame();

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{ 1, 2, 3 }, 40, 20);
    tabEvent(&ctx, mod_bits.shift);
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 3), ctx.state.focused_id);
}

test "Context: a click forwarded before the frame opens still reaches a widget" {
    var ctx = testCtx();
    defer ctx.deinit();

    // The order a native loop makes natural: take the window's events, then open the frame.
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });

    ctx.beginFrame(800, 600);
    const r = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(r.clicked);
    ctx.endFrame();
}

test "Context: composition set before the frame opens survives the caller's buffer" {
    var ctx = testCtx();
    defer ctx.deinit();

    {
        var scratch: [7]u8 = "preedit".*;
        ctx.setComposition(.{ .active = true, .text = &scratch, .cursor = 7 });
        @memset(&scratch, 'x');
    }
    ctx.beginFrame(800, 600);
    try std.testing.expect(ctx.composition.active);
    try std.testing.expectEqualStrings("preedit", ctx.composition.text);
    ctx.endFrame();

    // Frame-local: the next frame starts with no preedit unless the caller sets one again.
    ctx.beginFrame(800, 600);
    try std.testing.expect(!ctx.composition.active);
    ctx.endFrame();
}

test "Context: the lifecycle contracts hold for ordinary use" {
    var ctx = testCtx();
    defer ctx.deinit();

    // A frame that opens and closes, with matched box, disabled and slider-group scopes, passes
    // every check on the way through.
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{});
    ctx.beginDisabled();
    ctx.label("disabled");
    ctx.endDisabled();
    ctx.endBox();
    ctx.endFrame();
    _ = ctx.postFrameDrawList();

    // Popup builders are ordinary frame-build calls, just like other layer consumers.
    ctx.beginFrame(800, 600);
    var popup_state: PopupState = .{
        .key = .{ .value = 1 },
        .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } },
    };
    _ = ctx.popupMenu(&popup_state, &.{});
    ctx.endFrame();
}

test "Context: a slider group opened and closed in one frame leaves no state behind" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.beginSliderGroup(.{});
    var value: i32 = 5;
    _ = ctx.sliderI32Id(1, "value", &value, .{ .min = 0, .max = 10 });
    ctx.endSliderGroup();
    ctx.endFrame();

    try std.testing.expect(ctx.slider_group == null);
    try std.testing.expectEqual(@as(u32, 0), ctx.disabled_depth);
}

fn countTextCmds(ctx: *Context) usize {
    var n: usize = 0;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .text) n += 1;
    }
    return n;
}

fn firstText(ctx: *Context) ?draw.DrawCmd {
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .text) return cmd;
    }
    return null;
}

test "label: explicit newline is two lines without wrap" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{});
    ctx.label("a\nb");
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 2), countTextCmds(&ctx));
    var i: usize = 0;
    var texts: [2][]const u8 = .{ "", "" };
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .text) {
            texts[i] = cmd.text.text;
            i += 1;
        }
    }
    try std.testing.expectEqualStrings("a", texts[0]);
    try std.testing.expectEqualStrings("b", texts[1]);
}

test "label: control-free non-wrap is one command and bit-identical to the prior contract" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{});
    ctx.label("hello");
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 1), countTextCmds(&ctx));
    const cmd = firstText(&ctx).?.text;
    try std.testing.expectEqualStrings("hello", cmd.text);
    try std.testing.expectEqual(@as(i32, 0), cmd.pos.x);
    try std.testing.expectEqual(@as(i32, 0), cmd.pos.y);
    try std.testing.expectEqual(@as(u32, 800), cmd.clip.w);
    try std.testing.expectEqual(@as(u32, 600), cmd.clip.h);
}

test "text: wrap emits one command per logical line" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(40, 200);
    ctx.beginBox(.{ .width = .{ .fixed = 40 }, .height = .fit });
    ctx.text("hello world", .{ .wrap = true });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 2), countTextCmds(&ctx));
}

test "text: leaf clip is baked as ancestor clip intersect self rect" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{ .width = .{ .fixed = 80 }, .height = .{ .fixed = 16 }, .clip_children = true });
    ctx.text("abcdefghijklmnop", .{ .overflow = .clip });
    ctx.endBox();
    ctx.endFrame();
    const cmd = firstText(&ctx).?.text;
    try std.testing.expectEqual(@as(i32, 0), cmd.clip.x);
    try std.testing.expectEqual(@as(u32, 80), cmd.clip.w);
    try std.testing.expectEqual(@as(u32, 16), cmd.clip.h);
}

test "text: ellipsis + max_lines=0 is one line with a marker (wrap on and off)" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(40, 200);
    ctx.beginBox(.{ .direction = .column, .width = .{ .fixed = 40 }, .gap = 4 });
    ctx.text("abcdefghij", .{ .overflow = .ellipsis });
    ctx.text("abcdefghij", .{ .wrap = true, .overflow = .ellipsis });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 2), countTextCmds(&ctx));
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .text) {
            try std.testing.expect(std.mem.endsWith(u8, cmd.text.text, "..."));
            try std.testing.expect(@as(i32, @intCast(ctx.font.measure(cmd.text.text))) <= 40);
        }
    }
}

test "text: visible + max_lines=0 is unlimited" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(24, 400);
    ctx.beginBox(.{ .width = .{ .fixed = 24 }, .height = .fit });
    ctx.text("one two three four five", .{ .wrap = true });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expect(countTextCmds(&ctx) > 2);
}

test "text: clip + max_lines>0 hard-cuts without an ellipsis" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(24, 200);
    ctx.beginBox(.{ .width = .{ .fixed = 24 }, .height = .fit });
    ctx.text("one two three four", .{ .wrap = true, .max_lines = 2, .overflow = .clip });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 2), countTextCmds(&ctx));
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .text) try std.testing.expect(!std.mem.endsWith(u8, cmd.text.text, "..."));
    }
}

test "text: ellipsis + max_lines=3 puts the marker on the last visible line" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(24, 200);
    ctx.beginBox(.{ .width = .{ .fixed = 24 }, .height = .fit });
    ctx.text("one two three four five", .{ .wrap = true, .max_lines = 3, .overflow = .ellipsis });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 3), countTextCmds(&ctx));
    var last: []const u8 = "";
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .text) last = cmd.text.text;
    }
    try std.testing.expect(std.mem.endsWith(u8, last, "..."));
}

test "text: visible + max_lines>0 hard-cuts logical lines" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(24, 200);
    ctx.beginBox(.{ .width = .{ .fixed = 24 }, .height = .fit });
    ctx.text("one two three four", .{ .wrap = true, .max_lines = 2, .overflow = .visible });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 2), countTextCmds(&ctx));
}

test "text: non-wrap explicit newline + ellipsis width-guarantees every line" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(40, 200);
    ctx.beginBox(.{ .width = .{ .fixed = 40 } });
    ctx.text("abcdefgh\nx", .{ .max_lines = 2, .overflow = .ellipsis });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 2), countTextCmds(&ctx));
    var i: usize = 0;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd != .text) continue;
        try std.testing.expect(@as(i32, @intCast(ctx.font.measure(cmd.text.text))) <= 40);
        if (i == 0) try std.testing.expect(std.mem.endsWith(u8, cmd.text.text, "..."));
        if (i == 1) try std.testing.expectEqualStrings("x", cmd.text.text);
        i += 1;
    }
}

test "text: non-wrap explicit newline + max_lines ellipsis targets the last visible line" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(200, 200);
    ctx.beginBox(.{ .width = .{ .fixed = 200 } });
    ctx.text("one\ntwo\nthree", .{ .max_lines = 2, .overflow = .ellipsis });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 2), countTextCmds(&ctx));
    var last: []const u8 = "";
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .text) last = cmd.text.text;
    }
    try std.testing.expect(std.mem.endsWith(u8, last, "..."));
}

const tier_fields = @typeInfo(style_mod.TextTier).@"enum".fields;
const tier_count = tier_fields.len;

/// Draw one label per tier and collect the resulting text commands, in tier order. Walking the
/// enum rather than a hand-written list is what makes a new tier join these tests by itself.
fn labelEveryTier(ctx: *Context, out_color: *[tier_count]Color, out_font: *[tier_count]?Font) !void {
    ctx.beginFrame(800, 400);
    ctx.beginBox(.{ .direction = .column });
    inline for (tier_fields) |field| {
        ctx.labelStyled(field.name, @field(style_mod.TextTier, field.name));
    }
    ctx.endBox();
    ctx.endFrame();
    var n: usize = 0;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd != .text) continue;
        if (n == tier_count) return error.TestUnexpectedResult;
        out_color[n] = cmd.text.color;
        out_font[n] = cmd.text.font;
        n += 1;
    }
    try std.testing.expectEqual(tier_count, n);
}

test "labelStyled: each tier uses the matching style color and context font" {
    var ctx = testCtx();
    defer ctx.deinit();
    var colors: [tier_count]Color = undefined;
    var fonts: [tier_count]?Font = undefined;
    try labelEveryTier(&ctx, &colors, &fonts);
    inline for (tier_fields, 0..) |field, i| {
        const tier = @field(style_mod.TextTier, field.name);
        try std.testing.expectEqual(ctx.style.textStyle(tier).color, colors[i]);
        // A bitmap context font ignores the tier's size and weight, so every tier draws with it.
        try std.testing.expectEqual(ctx.font.ptr, fonts[i].?.ptr);
    }
}

test "labelStyled: a non-null tier font is carried onto the draw command" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.style.text_styles[style_mod.tierIndex(.title)].font = font_mod.defaultOutlineFont();
    ctx.beginFrame(400, 80);
    ctx.labelStyled("Title", .title);
    ctx.endFrame();
    const cmd = firstText(&ctx).?.text;
    try std.testing.expect(cmd.font != null);
    try std.testing.expectEqual(ctx.style.textStyle(.title).font.?.ptr, cmd.font.?.ptr);
}

test "labelStyled: the outline default resolves a distinct variant for every tier" {
    var ctx = Context.init(std.testing.allocator, font_mod.default_outline_font);
    defer ctx.deinit();
    var colors: [tier_count]Color = undefined;
    var fonts: [tier_count]?Font = undefined;
    try labelEveryTier(&ctx, &colors, &fonts);

    // The face each tier drew with has to be the one its own size and weight resolve to.
    // Distinct pointers and a descending line height do not say that: every tier resolving at
    // weight 400, or at `size + 1`, satisfies both. Resolving the variant here from the tier's
    // own `TextStyle` and comparing identity is what pins the pair that was actually passed.
    inline for (tier_fields, 0..) |field, i| {
        const ts = ctx.style.textStyle(@field(style_mod.TextTier, field.name));
        const want = try font_mod.defaultFontFamily().variant(ts.size, ts.weight);
        try std.testing.expectEqual(want.ptr, fonts[i].?.ptr);
    }
    // `variantOutline` keys its cache on `quantizePx(size)` plus weight, so two tiers sharing a
    // quantized (size, weight) would share one variant pointer. Distinct pointers across every
    // pair is the executable form of "no two tiers resolve to the same face".
    for (fonts, 0..) |a, i| {
        for (fonts[i + 1 ..]) |b| {
            try std.testing.expect(a.?.ptr != b.?.ptr);
        }
    }
    // Declaration order is largest to smallest, so the resolved faces descend with it.
    inline for (tier_fields, 0..) |_, i| {
        if (i == 0) continue;
        try std.testing.expect(fonts[i].?.metrics().line_height <= fonts[i - 1].?.metrics().line_height);
    }
}

test "labelStyled: uses the text path for paragraphs and overflow" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(800, 200);
    ctx.beginBox(.{ .direction = .column, .gap = 4 });
    ctx.labelStyled("a\nb", .body);
    ctx.text("a\nb", .{});
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 4), countTextCmds(&ctx));
    var texts: [4][]const u8 = .{ "", "", "", "" };
    var i: usize = 0;
    for (ctx.postFrameDrawList().cmds.items) |cmd| {
        if (cmd == .text) {
            texts[i] = cmd.text.text;
            i += 1;
        }
    }
    try std.testing.expectEqualStrings("a", texts[0]);
    try std.testing.expectEqualStrings("b", texts[1]);
    try std.testing.expectEqualStrings(texts[0], texts[2]);
    try std.testing.expectEqualStrings(texts[1], texts[3]);
}

test "text: explicit-ID previous-frame rect and hit-test ignore leaf overflow" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 42;
    ctx.beginFrame(200, 80);
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = 80 }, .height = .{ .fixed = 20 } });
    ctx.text("abcdefghijklmnop", .{ .overflow = .clip });
    ctx.endBox();
    ctx.endFrame();
    const cached = ctx.getNodeCachedRect(id).?;
    try std.testing.expectEqual(@as(u32, 80), cached.rect.w);
    try std.testing.expectEqual(@as(u32, 20), cached.rect.h);
    try std.testing.expectEqual(@as(u32, 200), cached.clip.w);

    ctx.beginFrame(200, 80);
    const again = ctx.getNodeCachedRect(id).?;
    try std.testing.expectEqual(cached.rect, again.rect);
    try std.testing.expectEqual(cached.clip, again.clip);
    const hit = buttonBehavior(&ctx, id, again.rect, again.clip);
    _ = hit;
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = 80 }, .height = .{ .fixed = 20 } });
    ctx.text("abcdefghijklmnop", .{ .overflow = .clip });
    ctx.endBox();
    ctx.endFrame();
}

test "text: ScrollArea natural height appears next frame and converges in two frames after a width change" {
    var ctx = testCtx();
    defer ctx.deinit();
    const sid: Id = 100;
    const content_id = id_mod.hashInt(sid, 1);
    var scroll = Vec2f{ .x = 0, .y = 0 };
    const opts = widgets.ScrollAreaOpts{ .content_width = .{ .grow = 1 } };

    // Frame 1: no previous measured. After endFrame the wrap height is in the cache
    // (the scrollbar itself appears next frame — previous-frame contract).
    ctx.beginFrame(40, 40);
    try std.testing.expect(ctx.getNodeMeasured(content_id) == null);
    ctx.beginScrollArea(sid, &scroll, opts);
    ctx.text("hello world hello world", .{ .wrap = true });
    ctx.endScrollArea();
    ctx.endFrame();
    const h1 = ctx.getNodeMeasured(content_id).?.y;
    try std.testing.expect(h1 > 16);

    // Frame 2: beginScrollArea reads h1. A newly appearing scrollbar can change
    // the wrap width, so measured_h may move once more.
    ctx.beginFrame(40, 40);
    try std.testing.expectEqual(h1, ctx.getNodeMeasured(content_id).?.y);
    ctx.beginScrollArea(sid, &scroll, opts);
    ctx.text("hello world hello world", .{ .wrap = true });
    ctx.endScrollArea();
    ctx.endFrame();

    ctx.beginFrame(40, 40);
    ctx.beginScrollArea(sid, &scroll, opts);
    ctx.text("hello world hello world", .{ .wrap = true });
    ctx.endScrollArea();
    ctx.endFrame();
    const h_stable = ctx.getNodeMeasured(content_id).?.y;
    ctx.beginFrame(40, 40);
    try std.testing.expectEqual(h_stable, ctx.getNodeMeasured(content_id).?.y);
    ctx.beginScrollArea(sid, &scroll, opts);
    ctx.text("hello world hello world", .{ .wrap = true });
    ctx.endScrollArea();
    ctx.endFrame();
    try std.testing.expectEqual(h_stable, ctx.getNodeMeasured(content_id).?.y);

    // Width change: this frame still sees the old height; the next frame settles.
    ctx.beginFrame(80, 40);
    try std.testing.expectEqual(h_stable, ctx.getNodeMeasured(content_id).?.y);
    ctx.beginScrollArea(sid, &scroll, opts);
    ctx.text("hello world hello world", .{ .wrap = true });
    ctx.endScrollArea();
    ctx.endFrame();
    const h_after_resize = ctx.getNodeMeasured(content_id).?.y;
    try std.testing.expect(h_after_resize < h_stable);

    ctx.beginFrame(80, 40);
    ctx.beginScrollArea(sid, &scroll, opts);
    ctx.text("hello world hello world", .{ .wrap = true });
    ctx.endScrollArea();
    ctx.endFrame();
    try std.testing.expectEqual(h_after_resize, ctx.getNodeMeasured(content_id).?.y);
}

test "ellipsizeText: Context wrapper matches text_wrap.truncate" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(200, 40);
    const via_ctx = ctx.ellipsizeText("a-very-long-file-name-that-does-not-fit-the-column.txt", 80);
    const via_mod = text_wrap_mod.truncate(ctx.allocator(), ctx.font, "a-very-long-file-name-that-does-not-fit-the-column.txt", 80) catch unreachable;
    try std.testing.expectEqualStrings(via_mod.text, via_ctx.text);
    try std.testing.expectEqual(via_mod.truncated, via_ctx.truncated);
    ctx.endFrame();
}

test "extent: unrecorded CachedRect falls back to measured" {
    const cached = CachedRect{
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .clip = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .measured_w = 80,
        .measured_h = 40,
    };
    try std.testing.expectEqual(@as(i32, -1), cached.content_w);
    try std.testing.expectEqual(@as(i32, -1), cached.declared_w);
    try std.testing.expectEqual(@as(i32, 80), cached.scrollContentSize().x);
    try std.testing.expectEqual(@as(i32, 40), cached.scrollContentSize().y);
}

test "extent: declared fixed wins over a smaller recorded extent" {
    const cached = CachedRect{
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .clip = .{ .x = 0, .y = 0, .w = 40, .h = 40 },
        .measured_w = 40,
        .measured_h = 10,
        .content_w = 40,
        .content_h = 10,
        .declared_w = -1,
        .declared_h = 500,
    };
    try std.testing.expectEqual(@as(i32, 40), cached.scrollContentSize().x);
    try std.testing.expectEqual(@as(i32, 500), cached.scrollContentSize().y);
}

test "extent: ScrollArea uses previous-frame extent for max_y on a grow wrap content box" {
    var ctx = testCtx();
    defer ctx.deinit();
    const sid: Id = 0x3040;
    const content_id = id_mod.hashInt(sid, 1);
    var scroll = Vec2f{ .x = 0, .y = 0 };
    const opts = widgets.ScrollAreaOpts{
        .width = .{ .fixed = 80 },
        .height = .{ .fixed = 40 },
        .content_width = .{ .grow = 1 },
        .content_height = .{ .grow = 1 },
    };

    ctx.beginFrame(80, 40);
    ctx.beginScrollArea(sid, &scroll, opts);
    ctx.beginBox(.{
        .direction = .row,
        .wrap = true,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .gap = 0,
    });
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        ctx.beginBox(.{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 16 } });
        ctx.endBox();
    }
    ctx.endBox();
    ctx.endScrollArea();
    ctx.endFrame();

    const cached = ctx.getNodeCachedRect(content_id).?;
    try std.testing.expectEqual(@as(i32, 0), cached.measured_h);
    try std.testing.expect(cached.content_h > cached.measured_h);
    try std.testing.expect(cached.content_h > 40);

    scroll.y = 9999;
    ctx.beginFrame(80, 40);
    ctx.beginScrollArea(sid, &scroll, opts);
    ctx.beginBox(.{
        .direction = .row,
        .wrap = true,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .gap = 0,
    });
    i = 0;
    while (i < 6) : (i += 1) {
        ctx.beginBox(.{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 16 } });
        ctx.endBox();
    }
    ctx.endBox();
    ctx.endScrollArea();
    ctx.endFrame();

    const max_y = cached.content_h - 40;
    try std.testing.expect(max_y > 0);
    try std.testing.expectEqual(@as(f32, @floatFromInt(max_y)), scroll.y);
}

test "extent: ScrollArea prefers a declared fixed content size over extent (virtual-list shape)" {
    var ctx = testCtx();
    defer ctx.deinit();
    const sid: Id = 0x3041;
    const content_id = id_mod.hashInt(sid, 1);
    var scroll = Vec2f{ .x = 0, .y = 0 };
    const opts = widgets.ScrollAreaOpts{
        .width = .{ .fixed = 80 },
        .height = .{ .fixed = 40 },
        .content_width = .{ .grow = 1 },
        .content_height = .{ .fixed = 500 },
    };

    ctx.beginFrame(80, 40);
    ctx.beginScrollArea(sid, &scroll, opts);
    ctx.beginBox(.{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 16 } });
    ctx.endBox();
    ctx.endScrollArea();
    ctx.endFrame();

    const cached = ctx.getNodeCachedRect(content_id).?;
    try std.testing.expectEqual(@as(i32, 500), cached.declared_h);
    try std.testing.expect(cached.content_h < 500);
    try std.testing.expectEqual(@as(i32, 500), cached.scrollContentSize().y);

    scroll.y = 9999;
    ctx.beginFrame(80, 40);
    ctx.beginScrollArea(sid, &scroll, opts);
    ctx.beginBox(.{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 16 } });
    ctx.endBox();
    ctx.endScrollArea();
    ctx.endFrame();

    try std.testing.expectEqual(@as(f32, 460), scroll.y);
}

test "wrap: beginBox accepts a legal wrap config" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(100, 80);
    ctx.beginBox(.{ .direction = .row, .wrap = true, .width = .{ .fixed = 80 }, .height = .fit });
    ctx.beginBox(.{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 10 } });
    ctx.endBox();
    ctx.beginBox(.{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 10 } });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();
}

test "Context: disabled animation does not create per-ID state" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrameAt(160, 80, 0);
    ctx.state.hot_id = 41;
    const colors = ctx.resolveButtonColors(41, ctx.style.bg, false, true, false);
    ctx.endFrame();

    try std.testing.expectEqual(ctx.style.bg_active, colors.bg);
    try std.testing.expectEqual(@as(usize, 0), ctx.per_id_state.count());
}

test "Context: enabled animation avoids lookup for inactive widgets" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.style.animation.enabled = true;

    ctx.beginFrameAt(160, 80, 0);
    const colors = ctx.resolveButtonColors(42, ctx.style.bg, false, false, false);
    ctx.endFrame();

    try std.testing.expectEqual(ctx.style.bg, colors.bg);
    try std.testing.expectEqual(@as(usize, 0), ctx.per_id_state.count());
}

test "Context: animated button colors settle through an intermediate value" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.style.animation.enabled = true;

    ctx.beginFrameAt(160, 80, 0);
    ctx.state.hot_id = 43;
    const first = ctx.resolveButtonColors(43, ctx.style.bg, false, false, false);
    ctx.endFrame();

    ctx.beginFrameAt(160, 80, 0.05);
    ctx.state.hot_id = 43;
    const middle = ctx.resolveButtonColors(43, ctx.style.bg, false, false, false);
    ctx.endFrame();

    ctx.beginFrameAt(160, 80, 1.0);
    ctx.state.hot_id = 43;
    const settled = ctx.resolveButtonColors(43, ctx.style.bg, false, false, false);
    ctx.endFrame();

    try std.testing.expectEqual(ctx.style.bg, first.bg);
    try std.testing.expect(!std.meta.eql(ctx.style.bg, middle.bg));
    try std.testing.expect(!std.meta.eql(ctx.style.bg_hover, middle.bg));
    try std.testing.expectEqual(ctx.style.bg_hover, settled.bg);
}

test "button style override: normal hover held selected and disabled resolve every color" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 0x3098;
    const override: WidgetStyle = .{
        .background = Color.rgba(0x11, 0x22, 0x33, 0xFF),
        .hover = Color.rgba(0x44, 0x55, 0x66, 0xFF),
        .active = Color.rgba(0x77, 0x88, 0x99, 0xFF),
        .selected = Color.rgba(0xAA, 0xBB, 0xCC, 0xFF),
        .border = Color.rgba(0x12, 0x34, 0x56, 0xFF),
        .hover_border = Color.rgba(0x65, 0x43, 0x21, 0xFF),
        .text = Color.rgba(0xDE, 0xAD, 0xBE, 0xFF),
    };

    ctx.beginFrameAt(160, 80, 0);
    ctx.state.hot_id = 0;
    const normal = ctx.resolveButtonColorsWithStyle(id, ctx.style.surface.control, false, false, false, override);
    ctx.endFrame();
    try std.testing.expectEqual(override.background.?, normal.bg);
    try std.testing.expectEqual(override.border.?, normal.border);
    try std.testing.expectEqual(override.text.?, normal.text);

    ctx.beginFrameAt(160, 80, 1);
    ctx.state.hot_id = id;
    const hover = ctx.resolveButtonColorsWithStyle(id, ctx.style.surface.control, false, false, false, override);
    ctx.endFrame();
    try std.testing.expectEqual(override.hover.?, hover.bg);
    try std.testing.expectEqual(override.hover_border.?, hover.border);
    try std.testing.expectEqual(override.text.?, hover.text);

    ctx.beginFrameAt(160, 80, 2);
    ctx.state.hot_id = id;
    const held = ctx.resolveButtonColorsWithStyle(id, ctx.style.surface.control, false, true, false, override);
    ctx.endFrame();
    try std.testing.expectEqual(override.active.?, held.bg);
    try std.testing.expectEqual(override.hover_border.?, held.border);
    try std.testing.expectEqual(override.text.?, held.text);

    ctx.beginFrameAt(160, 80, 3);
    ctx.state.hot_id = 0;
    const selected = ctx.resolveButtonColorsWithStyle(id, ctx.style.surface.control, true, false, false, override);
    ctx.endFrame();
    try std.testing.expectEqual(override.selected.?, selected.bg);
    try std.testing.expectEqual(override.hover_border.?, selected.border);
    try std.testing.expectEqual(override.text.?, selected.text);

    ctx.beginFrameAt(160, 80, 4);
    ctx.state.hot_id = id;
    const disabled = ctx.resolveButtonColorsWithStyle(id, ctx.style.surface.control, false, false, true, override);
    ctx.endFrame();
    try std.testing.expectEqual(ctx.style.disabledColor(override.background.?), disabled.bg);
    try std.testing.expectEqual(ctx.style.disabledColor(override.border.?), disabled.border);
    try std.testing.expectEqual(ctx.style.disabledColor(override.text.?), disabled.text);
}

test "button style override: animation uses override colors as tween endpoints" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.style.animation.enabled = true;
    const id: Id = 0x3099;
    const override: WidgetStyle = .{
        .background = Color.rgba(0x10, 0x20, 0x30, 0xFF),
        .hover = Color.rgba(0x40, 0x50, 0x60, 0xFF),
        .active = Color.rgba(0x70, 0x80, 0x90, 0xFF),
        .border = Color.rgba(0x12, 0x23, 0x34, 0xFF),
        .hover_border = Color.rgba(0x56, 0x67, 0x78, 0xFF),
        .text = Color.rgba(0x9A, 0xAB, 0xBC, 0xFF),
    };

    ctx.beginFrameAt(160, 80, 0);
    ctx.state.hot_id = 0;
    _ = ctx.resolveButtonColorsWithStyle(id, ctx.style.surface.control, false, false, false, override);
    ctx.endFrame();

    ctx.beginFrameAt(160, 80, 0.01);
    ctx.state.hot_id = id;
    _ = ctx.resolveButtonColorsWithStyle(id, ctx.style.surface.control, false, false, false, override);
    ctx.endFrame();

    ctx.beginFrameAt(160, 80, 0.05);
    ctx.state.hot_id = id;
    const hover_middle = ctx.resolveButtonColorsWithStyle(id, ctx.style.surface.control, false, false, false, override);
    ctx.endFrame();
    try std.testing.expect(!std.meta.eql(override.background.?, hover_middle.bg));
    try std.testing.expect(!std.meta.eql(override.hover.?, hover_middle.bg));

    ctx.beginFrameAt(160, 80, 1.0);
    ctx.state.hot_id = id;
    const hover_settled = ctx.resolveButtonColorsWithStyle(id, ctx.style.surface.control, false, false, false, override);
    ctx.endFrame();
    try std.testing.expectEqual(override.hover.?, hover_settled.bg);
    try std.testing.expectEqual(override.hover_border.?, hover_settled.border);

    ctx.beginFrameAt(160, 80, 1.05);
    ctx.state.hot_id = id;
    _ = ctx.resolveButtonColorsWithStyle(id, ctx.style.surface.control, false, true, false, override);
    ctx.endFrame();

    ctx.beginFrameAt(160, 80, 2.0);
    ctx.state.hot_id = id;
    const press_settled = ctx.resolveButtonColorsWithStyle(id, ctx.style.surface.control, false, true, false, override);
    ctx.endFrame();
    try std.testing.expectEqual(override.active.?, press_settled.bg);
    try std.testing.expectEqual(override.hover_border.?, press_settled.border);
    try std.testing.expectEqual(override.text.?, press_settled.text);
}
