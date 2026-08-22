// Context: bundles input + ID stack + interaction state + draw list + arena + font + layout.
// Frame lifecycle (beginFrame / endFrame) and the starting point for widget behavior.
//
// Current contracts for lifecycle, sync hit-test, and clip visibility follow.
// Keep these comments aligned with the implementation below.
// Do not weaken the prohibitions (e.g. no trim inside the widget-build loop).
//
// Lifecycle contract (Context as the contract guardian + layout):
//   beginFrame(w,h): arena.reset → input/id_stack/state.beginFrame → per_id_state.beginFrame
//                    → draw_list.reset(w,h)  ※ w/h are logical size (not the physical fb)
//                    → allocate the implicit layout-tree root on the arena (not yet measure/place this frame)
//                    → apply input staged since the last frame (arrival order, edges already cleared)
//   input:           pushEvent / setComposition may be called at any point in the loop. Inside a
//                    frame they apply immediately; outside one they are staged and applied by the
//                    next beginFrame, so forwarding platform events before opening the frame is
//                    just as correct as forwarding them after (see StagedInput in input.zig).
//   widget calls: sync hit-test against the previous-frame rect_cache (never the layout rects still under construction)
//   endFrame():      layoutTree (measureWidths → placeWidths → wrapText →
//                    measureHeights → placeHeights) → rect_cache.clearRetainingCapacity
//                    → updateRectCache → emitNode (emit draw cmds) → frame_active=false
//                    → focus cleanup → active cleanup → PerIdStateStore.trim (frame boundary only)
//                    No hit-test here. The new rect_cache is referenced from the next frame after this endFrame completes.
//                    Does not touch the arena (Context is the contract guardian).
//                    After endFrame, draw_list / id_stack / state / the layout tree stay
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
// Draw emit order: layout cmds are appended after any cmds the caller pushed directly onto draw_list
// during the frame (= layout UI draws on top).

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("geom.zig");
const color_mod = @import("color.zig");
const draw = @import("draw.zig");
const font_mod = @import("font.zig");
const id_mod = @import("id.zig");
const input_mod = @import("input.zig");
const state_mod = @import("state.zig");
const layout = @import("layout.zig");
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
pub const Style = style_mod.Style;
pub const PerIdState = state_mod.PerIdState;
// Popup / context menu. Implementation and doc comments live in popup.zig.
pub const PopupState = popup_mod.PopupState;
pub const PopupStack = popup_mod.PopupStack;
pub const PopupItem = popup_mod.PopupItem;
pub const PopupResult = popup_mod.PopupResult;
pub const PopupMenuOpts = popup_mod.PopupMenuOpts;
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
    serial: u16 = 0,
};

/// Pick the wheel-chain head from previous-frame geometry: deepest record whose
/// viewport contains `mouse`, ties at the same depth broken by reverse end-order
/// (later `endScrollArea` wins). An empty / zero-size rect never matches.
///
/// This is the same scan order as end-time LIFO for nested areas, made unique
/// for same-depth overlapping siblings. Amounts are not decided here.
pub fn pickWheelChainHead(records: []const ScrollAreaRecord, mouse: Vec2) Id {
    var best_id: Id = 0;
    var best_depth: i32 = -1;
    var best_serial: i32 = -1;
    for (records) |rec| {
        if (rec.rect.w == 0 or rec.rect.h == 0) continue;
        const rw: i32 = @intCast(rec.rect.w);
        const rh: i32 = @intCast(rec.rect.h);
        const inside = mouse.x >= rec.rect.x and mouse.x < rec.rect.x + rw and
            mouse.y >= rec.rect.y and mouse.y < rec.rect.y + rh;
        if (!inside) continue;
        const deeper = @as(i32, rec.depth) > best_depth;
        const later = rec.depth == best_depth and @as(i32, rec.serial) > best_serial;
        if (deeper or later) {
            best_id = rec.id;
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

pub const Context = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    input: Input,
    id_stack: IdStack,
    state: InteractionState = .{},
    per_id_state: state_mod.PerIdStateStore = .{},
    draw_list: DrawList,
    font: Font,
    /// Non-null only when `font` is the deterministic default proxy. Tier variants borrow this
    /// family; custom bitmap or outline fonts stay untouched by tier size/weight.
    default_family: ?*font_mod.OutlineFontFamily = null,
    screen_w: u32 = 0,
    screen_h: u32 = 0,
    frame_active: bool = false,
    frame_index: u64 = 0,
    now_s: f64 = 0,
    /// Implicit root of the layout tree (allocated on the arena in beginFrame)
    layout_root: ?*layout.Node = null,
    /// beginBox / endBox cursor (current parent)
    layout_current: ?*layout.Node = null,
    /// Explicit-ID (cfg.id != 0) node id → {rect, clip}. GPA-owned, survives across frames, and
    /// is updated only in endFrame (first half of the frame still holds previous-frame values = sync hit-test contract).
    rect_cache: std.AutoHashMapUnmanaged(Id, CachedRect) = .empty,
    /// Widgets that took part in keyboard focus traversal this frame, in submission order —
    /// which is draw order, so Tab walks the interface the way it looks. Cleared every frame with
    /// the capacity kept, so a steady interface reallocates nothing after the first frame.
    focus_order: std.ArrayList(Id) = .empty,
    /// A Tab press waiting to be resolved at the end of the frame, once `focus_order` is complete.
    focus_move: enum { none, next, prev } = .none,
    /// Scroll-area begin→end state stack (supports nesting). Not on the arena (push/pop within the frame).
    scroll_stack: std.ArrayList(ScrollState) = .empty,
    /// Unconsumed wheel delta for the frame (seeded from input.scroll_delta at the first wheel apply).
    /// Each ScrollArea consumes only what it could move; remainder at an edge propagates outward.
    wheel_remaining: Vec2f = .{},
    wheel_remaining_seeded: bool = false,
    /// Previous-frame ScrollArea geometry (order only). Swapped with `scroll_areas_cur` in beginFrame.
    scroll_areas_prev: std.ArrayList(ScrollAreaRecord) = .empty,
    /// This frame's ScrollArea records, written in `endScrollArea` and given settled rects in endFrame.
    scroll_areas_cur: std.ArrayList(ScrollAreaRecord) = .empty,
    /// Whether `ensureWheelChain` has sealed this frame's chain head.
    wheel_chain_ready: bool = false,
    /// Viewport id of the chain head (0 = none). Only this area consumes wheel in begin.
    wheel_chain_head: Id = 0,
    /// Cursor used for every wheel hit-test this frame. Sealed with the chain
    /// so a later `pushEvent(mouse_move)` cannot retarget consumption.
    wheel_chain_mouse: Vec2 = .{ .x = 0, .y = 0 },
    /// Shared widget style. Caller may rewrite directly (no push/pop).
    style: Style,
    /// Popup / context-menu open state. The classic mechanism (openPopup/closePopup/popupMenu)
    /// allows only one of these open at a time. null = closed. When non-null, buttonBehavior
    /// suppresses hover/active on background widgets (modal absorption; see buttonBehavior's doc
    /// comment / popup.zig).
    popup_state: ?PopupState = null,
    /// Additional popups open through `openPopupStacked`, independent of `popup_state` above —
    /// see `PopupStack`'s doc comment in popup.zig for why this exists (a menu-bar dropdown and a
    /// context menu held open at once). Empty for every caller that never uses the stacked API,
    /// so it changes nothing for existing code.
    popup_stack: PopupStack = .{},
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
    /// Non-zero while a custom-tooltip builder is running. Interactive / state-mutating
    /// APIs are forbidden in this mode (lifecycle violation in every optimisation mode).
    display_only_depth: u32 = 0,
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
    pub const checkboxId = widgets.checkboxId;
    pub const toggle = widgets.toggle;
    pub const toggleId = widgets.toggleId;
    pub const radio = widgets.radio;
    pub const radioId = widgets.radioId;
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
    // Popup / context menu. Implementation and contract: see popup.zig.
    pub const openPopup = popup_mod.openPopup;
    pub const closePopup = popup_mod.closePopup;
    pub const hasOpenPopup = popup_mod.hasOpenPopup;
    pub const isPopupOpen = popup_mod.isPopupOpen;
    pub const popupMenu = popup_mod.popupMenu;
    pub const popupMenuEx = popup_mod.popupMenuEx;
    // Stacked popups (coexist with the classic slot above; see PopupStack in popup.zig).
    pub const openPopupStacked = popup_mod.openPopupStacked;
    pub const closePopupStacked = popup_mod.closePopupStacked;
    pub const isPopupOpenStacked = popup_mod.isPopupOpenStacked;
    pub const isPopupOpenAny = popup_mod.isPopupOpenAny;
    pub const openPopupCount = popup_mod.openPopupCount;
    pub const popupMenuStacked = popup_mod.popupMenuStacked;
    pub const popupPos = popup_mod.popupPos;
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
            .draw_list = DrawList.init(gpa),
            .font = font,
            .default_family = if (font_mod.isDefaultFont(font)) font_mod.defaultFontFamily() else null,
            .style = style_mod.defaultStyle(),
        };
    }

    pub fn deinit(self: *Context) void {
        self.rect_cache.deinit(self.gpa);
        self.per_id_state.deinit(self.gpa);
        self.focus_order.deinit(self.gpa);
        self.scroll_stack.deinit(self.gpa);
        self.scroll_areas_prev.deinit(self.gpa);
        self.scroll_areas_cur.deinit(self.gpa);
        self.draw_list.deinit();
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

    /// Copy `pixels` onto the frame arena. Valid until the next beginFrame.
    /// Use this when a tooltip builder generates a thumbnail that must outlive the call.
    pub fn dupePixels(self: *Context, pixels: []const u32) []u32 {
        return self.allocator().dupe(u32, pixels) catch @panic("dupePixels: OOM");
    }

    /// Start a filled path. Verbs and points go on the frame arena; `finish`
    /// appends one DrawCmd on success and nothing on InvalidPath or OOM.
    pub fn beginPath(self: *Context) draw.PathBuilder {
        return self.draw_list.beginPath(self.allocator());
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
        self.frame_active = true;
        self.screen_w = screen_w;
        self.screen_h = screen_h;
        self.now_s = now_s;
        _ = self.arena.reset(.retain_capacity); // Release the previous frame's payload and layout tree here
        self.input.beginFrame();
        self.id_stack.clear();
        self.state.beginFrame();
        self.per_id_state.beginFrame();
        self.composition = .{};
        self.focus_order.clearRetainingCapacity();
        self.focus_move = .none;
        self.wheel_remaining = .{};
        self.wheel_remaining_seeded = false;
        {
            const tmp = self.scroll_areas_prev;
            self.scroll_areas_prev = self.scroll_areas_cur;
            self.scroll_areas_cur = tmp;
            self.scroll_areas_cur.clearRetainingCapacity();
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
        self.display_only_depth = 0;
        self.tooltip_builder_calls = 0;
        self.tooltip_layout_calls = 0;
        self.frame_arena_allocs = 0;
        self.frame_arena_live = 0;
        self.frame_arena_peak = 0;
        self.drag_submitted_this_frame = false;
        // The cells a group collects live on the frame arena, so the group cannot outlive the frame.
        self.slider_group = null;
        self.table = null;
        self.draw_list.reset(screen_w, screen_h);
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

    /// Require an open frame: `beginFrame` has run and `endFrame` has not.
    pub inline fn requireFrame(self: *const Context, comptime what: []const u8) void {
        requireContract(self.frame_active, what ++ " requires an open frame");
    }

    /// Require that no frame is open — the contract of the post-frame APIs (popups, menu bar)
    /// and of opening a frame in the first place.
    pub inline fn requireNoFrame(self: *const Context, comptime what: []const u8) void {
        requireContract(!self.frame_active, what ++ " must be called with no frame open");
    }

    /// Require that a display-only tooltip builder is not running.
    ///
    /// Interactive widgets, focus / scroll / popup / drag mutation, per-id store
    /// touches, nested tooltips, and input injection are lifecycle violations
    /// inside a custom-tooltip builder. Checked at each public API entry, before
    /// any caller-owned write, so a first-frame (empty rect cache) call still
    /// fails. Panics in every optimisation mode (same class as `requireContract`).
    pub inline fn requireInteractiveAllowed(self: *const Context, comptime what: []const u8) void {
        requireContract(self.display_only_depth == 0, what ++ " is not allowed in a display-only tooltip builder");
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
        requireContract(self.display_only_depth == 0, "endFrame with a display-only tooltip builder still open");
        const root = self.layout_root.?;
        // Detect beginBox / endBox mismatches
        requireContract(self.layout_current == root, "endFrame with a box still open");
        // Frames that never use the layout API (empty root) skip layout / emit / cache update
        // entirely: compatible with manual DrawList use (examples 08/09). rect_cache keeps the previous values.
        if (root.first_child != null) {
            const screen_rect = Rect{ .x = 0, .y = 0, .w = self.screen_w, .h = self.screen_h };
            layout.layoutTree(root, screen_rect, self.font, self.allocator());
            self.rect_cache.clearRetainingCapacity();
            self.updateRectCache(root, screen_rect);
            self.emitNode(root);
        }
        // Seal this frame's viewport rects so the next frame's wheel chain reads
        // previous-frame geometry (same 1-frame lag as hit-test).
        for (self.scroll_areas_cur.items) |*rec| {
            if (self.rect_cache.get(rec.id)) |c| rec.rect = c.rect;
        }
        // tooltip overlay: after layout UI, before frame_active=false (below popupMenu; popup runs after endFrame).
        if (self.tooltip_candidate) |cand| {
            switch (cand) {
                .text => |tip| popup_mod.drawTooltipOverlay(self, tip, self.tooltip_candidate_anchor),
                .custom => |tip_root| {
                    self.tooltip_layout_calls += 1;
                    popup_mod.placeTooltipSubtree(
                        tip_root,
                        self.tooltip_candidate_anchor,
                        self.screen_w,
                        self.screen_h,
                        self.font,
                        self.allocator(),
                    );
                    const style = self.style;
                    self.draw_list.rectFilled(tip_root.rect, style.bg) catch @panic("tooltip: OOM");
                    self.draw_list.rectOutline(tip_root.rect, style.border, 1) catch @panic("tooltip: OOM");
                    self.emitNode(tip_root);
                },
            }
        }
        // If the target was not refreshed this frame, clear the timer (suppress stale overlays for hidden widgets)
        if (self.tooltip_hover_id != 0 and !self.tooltip_hover_refreshed) {
            self.tooltip_hover_id = 0;
        }
        self.frame_active = false;
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
        // PerIdStateStore LRU trim. Frame boundary only. Protects visible and in-use IDs.
        self.per_id_state.trim(.{
            .active_id = self.state.active_id,
            .focused_id = self.state.focused_id,
            .hot_id = self.state.hot_id,
            .next_hot_id = self.state.next_hot_id,
        });
        // Neither the arena nor draw_list is reset here (Context is the contract guardian).
    }

    /// Hand one input event to the GUI. Callable at any point in the loop: inside a frame it
    /// applies at once, outside one it is staged and applied by the next beginFrame, in arrival
    /// order (see `StagedInput` in input.zig). Note that staged input reaches `ctx.input` only
    /// when that frame opens, so reading `ctx.input` before beginFrame does not see it yet.
    pub fn pushEvent(self: *Context, ev: InputEvent) void {
        self.requireInteractiveAllowed("pushEvent");
        if (self.frame_active) {
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
        if (self.frame_active) {
            self.composition = state;
        } else {
            self.staged_input.setComposition(state);
        }
    }

    /// While a popup is open, background widgets' buttonBehavior never raises hover and
    /// this_frame_hovered_any stays false, so popup_state is ORed in explicitly
    /// (keeps "while modal absorption is active, wantsMouse() is effectively true". App canvas
    /// input gates can use this to suppress background input).
    pub fn wantsMouse(self: *const Context) bool {
        return self.state.active_id != 0 or self.state.this_frame_hovered_any or
            self.popup_state != null or self.popup_stack.len != 0;
    }

    pub fn wantsKeyboard(self: *const Context) bool {
        return self.state.focused_id != 0;
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
        if (id == 0) return false;
        self.state.focused_id = id;
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

    /// Enter `id` into this frame's Tab traversal, at the point it is submitted.
    ///
    /// Widgets call this themselves; an application only calls it for something it draws and
    /// hit-tests by hand. Submitting the widget is what puts it in the order, so a widget behind a
    /// closed branch leaves the order on its own. A widget behind an open popup is not submitted
    /// for these purposes at all — see the popup guard in `buttonBehavior`.
    ///
    /// Runs once per focusable widget per frame; the append is amortised free after the first
    /// frame because `focus_order` keeps its capacity.
    pub fn registerFocusable(self: *Context, id: Id) void {
        self.requireFrame("registerFocusable");
        self.requireInteractiveAllowed("registerFocusable");
        if (id == 0 or self.popup_state != null or self.popup_stack.len != 0) return;
        self.focus_order.append(self.gpa, id) catch @panic("Context.registerFocusable: OOM");
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

    /// Move the focus to the next or previous entry of this frame's traversal order.
    ///
    /// Called from endFrame after the draw commands are emitted, so the move lands on the *next*
    /// frame's drawing — the same generation rule the previous-frame hit-test follows (ADR-016).
    fn resolveFocusMove(self: *Context) void {
        const direction = self.focus_move;
        if (direction == .none) return;

        // Reachability is decided from the rect cache endFrame has just refreshed, so this reads
        // the geometry of the frame that is ending, not of the one before it.
        var reachable: usize = 0;
        for (self.focus_order.items) |id| {
            if (self.focusReachable(id)) reachable += 1;
        }
        // Nothing to land on. Leaving focus_claimed_this_frame alone matters: raising it here would
        // suppress the outside-click clear for a move that never happened.
        if (reachable == 0) return;

        const current = self.state.focused_id;
        var current_index: ?usize = null;
        for (self.focus_order.items, 0..) |id, i| {
            if (id == current and self.focusReachable(id)) {
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
                if (self.focusReachable(id)) break :blk id;
            }
            break :blk current;
        } else blk: {
            // The focus is gone (or was never in the order): start from whichever end the
            // direction implies.
            switch (direction) {
                .next => for (self.focus_order.items) |id| {
                    if (self.focusReachable(id)) break :blk id;
                },
                .prev => {
                    var i = self.focus_order.items.len;
                    while (i > 0) {
                        i -= 1;
                        const id = self.focus_order.items[i];
                        if (self.focusReachable(id)) break :blk id;
                    }
                },
                .none => unreachable,
            }
            unreachable; // reachable > 0 was checked above
        };

        self.state.focused_id = next_id;
        self.state.focus_visible = true;
        self.state.focus_claimed_this_frame = true;
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
        const pad = self.style.popup_padding;
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
        const saved_display = self.display_only_depth;

        self.layout_current = root;
        self.display_only_depth += 1;
        defer {
            self.layout_current = saved_layout;
            self.display_only_depth = saved_display;
        }

        build_fn(build_ctx, self);

        requireContract(self.layout_current == root, "tooltipBox builder left a box open");
        requireContract(self.disabled_depth == saved_disabled, "tooltipBox builder changed disabled depth");
        requireContract(self.scroll_stack.items.len == saved_scroll_len, "tooltipBox builder changed scroll stack");
        requireContract(sliderGroupUnchanged(self.slider_group, saved_slider), "tooltipBox builder changed slider group");
        requireContract(tableUnchanged(self.table, saved_table), "tooltipBox builder changed table");
        requireContract(widgets.collapsibleBodyDepth() == saved_collapsible, "tooltipBox builder changed collapsible depth");
        requireContract(self.display_only_depth == saved_display + 1, "tooltipBox builder changed display-only depth");
        requireContract(self.id_stack.stack.items.len == saved_id_len, "tooltipBox builder left the id stack unbalanced");
        requireContract(std.mem.eql(Id, self.id_stack.stack.items, saved_ids), "tooltipBox builder changed id stack contents");
        return root;
    }

    pub fn perIdState(self: *Context, id: Id) *state_mod.PerIdState {
        self.requireInteractiveAllowed("perIdState");
        std.debug.assert(id != 0);
        return self.per_id_state.getOrPut(self.gpa, id);
    }

    fn tooltipRectEq(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
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
        layout.appendChild(parent, node);
        self.layout_current = node;
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
    }

    /// text leaf (default color = style.text). str is duped onto the arena, so it does not
    /// depend on the caller buffer's lifetime. Paragraph breaks become multiple lines;
    /// paragraphs themselves are not wrapped (`overflow = .visible`).
    pub fn label(self: *Context, str: []const u8) void {
        self.labelEx(str, self.style.text);
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
        const col = opts.color orelse self.style.text;
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
    /// Duplicate explicit IDs in the same frame are a contract violation (Debug assert; Release last-wins overwrite,
    /// but callers must not use duplicate IDs).
    fn updateRectCache(self: *Context, node: *const layout.Node, clip: Rect) void {
        if (node.cfg.id != 0) {
            const gop = self.rect_cache.getOrPut(self.gpa, node.cfg.id) catch
                @panic("Context.endFrame: OOM");
            // Duplicate explicit IDs in the same frame are a contract violation (last-wins overwrite breaks hit-test)
            std.debug.assert(!gop.found_existing);
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
    fn emitNode(self: *Context, node: *const layout.Node) void {
        if (node.leaf) |leaf| {
            switch (leaf) {
                .text => |t| {
                    const clip_self = t.overflow == .clip;
                    if (clip_self) {
                        self.draw_list.pushClip(node.rect) catch @panic("Context.endFrame: OOM");
                    }
                    if (node.lines.len == 0) {
                        self.draw_list.textEx(
                            .{ .x = node.rect.x, .y = node.rect.y },
                            t.str,
                            t.color,
                            t.font,
                        ) catch @panic("Context.endFrame: OOM");
                    } else {
                        for (node.lines) |line| {
                            self.draw_list.textEx(
                                .{ .x = node.rect.x, .y = node.rect.y + line.y_offset },
                                line.text,
                                t.color,
                                t.font,
                            ) catch @panic("Context.endFrame: OOM");
                        }
                    }
                    if (clip_self) self.draw_list.popClip();
                },
                .custom => |c| c.draw_fn(c.ctx, &self.draw_list, node.rect),
            }
            return;
        }
        if (node.cfg.bg) |bg| {
            self.draw_list.rectFilledEx(node.rect, bg, .{ .radius = node.cfg.radius }) catch
                @panic("Context.endFrame: OOM");
        }
        if (node.cfg.clip_children) {
            self.draw_list.pushClip(layout.contentBox(node.rect, node.cfg.padding)) catch
                @panic("Context.endFrame: OOM");
        }
        var it = node.first_child;
        while (it) |c| : (it = c.next_sibling) self.emitNode(c);
        if (node.cfg.clip_children) self.draw_list.popClip();
        if (node.cfg.border) |b| {
            self.draw_list.rectOutlineEx(node.rect, b.color, b.thickness, .{ .radius = node.cfg.radius }) catch
                @panic("Context.endFrame: OOM");
        }
        // Focus ring, on the same terms as the border: this frame's rect, after popClip, so it sits
        // above the children and is clipped by the ancestor rather than by the node's own clip.
        // A widget draws no ring of its own — the ring belongs to whichever node carries the id, and
        // updateRectCache has already asserted that only one node per frame does.
        // A ring behind an open popup would point at a widget the popup has taken input away from,
        // so none is drawn while one is open.
        if (self.popup_state == null and self.popup_stack.len == 0 and self.state.focus_visible and
            node.cfg.id != 0 and node.cfg.id == self.state.focused_id)
        {
            self.draw_list.rectOutlineEx(
                node.rect,
                self.style.focus_ring,
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
    ctx.requireFrame("buttonBehavior");
    ctx.requireInteractiveAllowed("buttonBehavior");
    // Modal absorption: while a popup is open (the classic slot or a stacked one — see
    // popup.zig's PopupStack), background widgets get no hover/hot/active at all.
    // popup.openPopup()/openPopupStacked() always reset active_id/hot_id/next_hot_id to 0 on
    // open, so there is no special case for "already-active widgets"; this guard alone blocks
    // new acquires, and active_id cannot become non-zero while a popup is open.
    // The popup itself uses manual hit-test (hitTestItem in popup.zig) and does not go through
    // buttonBehavior, so this guard does not affect it.
    if (ctx.popup_state != null or ctx.popup_stack.len != 0) return .{};

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

    try std.testing.expectEqual(@as(usize, 3), ctx.draw_list.cmds.items.len);
    try std.testing.expectEqual(@as(u32, 9), ctx.draw_list.cmds.items[0].rect_filled.radius);
    try std.testing.expect(ctx.draw_list.cmds.items[0].rect_filled.aa);
    try std.testing.expectEqual(@as(u32, 9), ctx.draw_list.cmds.items[1].rect_outline.radius);
    try std.testing.expect(ctx.draw_list.cmds.items[1].rect_outline.aa);
    try std.testing.expectEqual(@as(u32, 9), ctx.draw_list.cmds.items[2].rect_outline.radius);
    try std.testing.expect(ctx.draw_list.cmds.items[2].rect_outline.aa);
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
    const root = ctx.draw_list.clip_stack.items[0];
    try std.testing.expectEqual(@as(u32, 320), root.w);
    try std.testing.expectEqual(@as(u32, 240), root.h);
    try std.testing.expectEqual(@as(i32, 320), ctx.layout_root.?.cfg.width.fixed);
    try std.testing.expectEqual(@as(i32, 240), ctx.layout_root.?.cfg.height.fixed);
    ctx.endFrame();
}

test "Context: beginFrame resets; endFrame keeps draw_list/id_stack/state" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    try ctx.draw_list.rectFilled(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, color_mod.Color.rgba(0xFF, 0, 0, 0xFF));
    ctx.id_stack.push("scope");
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    ctx.endFrame();

    // Still valid after endFrame (referenceable until the next beginFrame)
    try std.testing.expect(ctx.draw_list.cmds.items.len > 0);
    try std.testing.expect(ctx.id_stack.stack.items.len > 0);
    try std.testing.expect(ctx.state.this_frame_hovered_any);

    // Reset on the next beginFrame
    ctx.beginFrame(800, 600);
    try std.testing.expectEqual(@as(usize, 0), ctx.draw_list.cmds.items.len);
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
    try std.testing.expectEqual(@as(usize, 2), ctx.draw_list.cmds.items.len);
    const bg_clip = ctx.draw_list.cmds.items[0].rect_filled.clip;
    try std.testing.expectEqual(@as(u32, 800), bg_clip.w);
    const text_clip = ctx.draw_list.cmds.items[1].text.clip;
    try std.testing.expectEqual(@as(i32, 0), text_clip.x);
    try std.testing.expectEqual(@as(u32, 100), text_clip.w);
    try std.testing.expectEqual(@as(u32, 40), text_clip.h);
}

test "anchor: clip_children clips an overflowing overlay's draw commands" {
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
        .anchor = .{ .at = .top_right, .offset = .{ .x = 16, .y = -8 } },
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
    for (ctx.draw_list.cmds.items) |cmd| {
        if (cmd != .rect_filled) continue;
        if (cmd.rect_filled.paint != .solid or !std.meta.eql(cmd.rect_filled.paint.solid, Color.rgba(0xC0, 0x30, 0x30, 0xFF))) continue;
        try std.testing.expectEqual(@as(i32, 0), cmd.rect_filled.clip.x);
        try std.testing.expectEqual(@as(u32, 40), cmd.rect_filled.clip.w);
        try std.testing.expectEqual(@as(u32, 40), cmd.rect_filled.clip.h);
        found = true;
    }
    try std.testing.expect(found);
}

test "anchor: an explicit id is cached and hit-tested" {
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
        .anchor = .{ .at = .top_right, .offset = .{ .x = 4, .y = -4 } },
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

test "anchor: a tree with no overlay keeps the pre-overlay rect and DrawCmd contract" {
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

    try std.testing.expect(!ctx.layout_root.?.has_anchored_child);
    try std.testing.expectEqual(ctx.layout_root.?.child_count, ctx.layout_root.?.flow_child_count);

    const row_r = ctx.getNodeRect(row).?;
    const left_r = ctx.getNodeRect(left).?;
    const right_r = ctx.getNodeRect(right).?;
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 200, .h = 40 }, row_r);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 40, .h = 16 }, left_r);
    try std.testing.expectEqual(Rect{ .x = 44, .y = 0, .w = 156, .h = 40 }, right_r);

    try std.testing.expectEqual(@as(usize, 5), ctx.draw_list.cmds.items.len);
    try std.testing.expect(ctx.draw_list.cmds.items[0] == .rect_filled);
    try std.testing.expectEqual(row_r, ctx.draw_list.cmds.items[0].rect_filled.rect);
    try std.testing.expectEqual(red, ctx.draw_list.cmds.items[0].rect_filled.paint.solid);
    try std.testing.expectEqual(left_r, ctx.draw_list.cmds.items[1].rect_filled.rect);
    try std.testing.expectEqual(blue, ctx.draw_list.cmds.items[1].rect_filled.paint.solid);
    try std.testing.expectEqualStrings("ab", ctx.draw_list.cmds.items[2].text.text);
    try std.testing.expectEqual(@as(i32, 0), ctx.draw_list.cmds.items[2].text.pos.x);
    try std.testing.expectEqual(@as(i32, 0), ctx.draw_list.cmds.items[2].text.pos.y);
    try std.testing.expectEqual(right_r, ctx.draw_list.cmds.items[3].rect_filled.rect);
    try std.testing.expectEqual(green, ctx.draw_list.cmds.items[3].rect_filled.paint.solid);
    try std.testing.expectEqualStrings("cd", ctx.draw_list.cmds.items[4].text.text);
    try std.testing.expectEqual(@as(i32, 44), ctx.draw_list.cmds.items[4].text.pos.x);
    try std.testing.expectEqual(@as(i32, 0), ctx.draw_list.cmds.items[4].text.pos.y);
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

    try std.testing.expectEqualStrings("hello", ctx.draw_list.cmds.items[0].text.text);
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
    try std.testing.expectEqual(@as(usize, 0), ctx.draw_list.cmds.items.len);
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
    try std.testing.expectEqual(@as(usize, 1), ctx.draw_list.cmds.items.len);
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

    try std.testing.expectEqual(@as(usize, 3), ctx.draw_list.cmds.items.len);
    try std.testing.expect(ctx.draw_list.cmds.items[0] == .rect_filled);
    try std.testing.expect(ctx.draw_list.cmds.items[1] == .text);
    const outline = ctx.draw_list.cmds.items[2].rect_outline;
    try std.testing.expectEqual(@as(u32, 2), outline.thickness);
    try std.testing.expectEqual(@as(u32, 100), outline.rect.w);
}

test "label: default color follows style.text" {
    var ctx = testCtx();
    defer ctx.deinit();

    const red = Color.rgba(0xFF, 0x00, 0x00, 0xFF);
    ctx.style.text = red;
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{});
    ctx.label("hello");
    ctx.endBox();
    ctx.endFrame();

    try std.testing.expectEqual(red, ctx.draw_list.cmds.items[0].text.color);
}

// ──────────────────────────────────────────────
// tooltip
// ──────────────────────────────────────────────

fn tooltipHasText(ctx: *const Context, expected: []const u8) bool {
    for (ctx.draw_list.cmds.items) |cmd| {
        // Path commands are not tooltip labels; only `.text` is inspected.
        if (cmd == .text and std.mem.eql(u8, cmd.text.text, expected)) return true;
    }
    return false;
}

fn tooltipOverlayBgRect(ctx: *const Context, tip: []const u8) ?Rect {
    // After endFrame: … layout cmds … then tooltip: rect_filled, rect_outline, text
    var i: usize = 0;
    while (i < ctx.draw_list.cmds.items.len) : (i += 1) {
        const cmd = ctx.draw_list.cmds.items[i];
        if (cmd == .text and std.mem.eql(u8, cmd.text.text, tip)) {
            if (i >= 2 and ctx.draw_list.cmds.items[i - 2] == .rect_filled) {
                return ctx.draw_list.cmds.items[i - 2].rect_filled.rect;
            }
            return null;
        }
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

test "tooltip: overlay appends text at the end of the draw list" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrameAt(800, 600, 0.0);
    _ = ctx.buttonId(1, "Btn", .{});
    ctx.endFrame();
    const before_tip_len = blk: {
        hoverButtonWithTip(&ctx, 1, "Btn", "tail tip", 0.0);
        break :blk ctx.draw_list.cmds.items.len;
    };
    hoverButtonWithTip(&ctx, 1, "Btn", "tail tip", 0.5);
    const cmds = ctx.draw_list.cmds.items;
    try std.testing.expect(cmds.len > before_tip_len);
    try std.testing.expect(cmds[cmds.len - 1] == .text);
    try std.testing.expectEqualStrings("tail tip", cmds[cmds.len - 1].text.text);
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
    for (ctx.draw_list.cmds.items) |cmd| {
        if (cmd == .image) {
            saw_image = true;
            try std.testing.expectEqual(@as(u32, 2), cmd.image.src_w);
            try std.testing.expectEqual(@as(u32, 2), cmd.image.src_h);
            try std.testing.expectEqual(@as(u32, 0xFF112233), cmd.image.pixels[0]);
        }
    }
    try std.testing.expect(saw_image);
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

test "focus traversal: an open popup takes widgets out of the order" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{ 1, 2 }, 40, 20);
    ctx.endFrame();

    ctx.popup_state = .{ .id = 99, .pos = .{ .x = 0, .y = 0 } };
    ctx.beginFrame(800, 600);
    focusFrame(&ctx, &.{ 1, 2 }, 40, 20);
    tabEvent(&ctx, 0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 0), ctx.focus_order.items.len);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.focused_id);
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
    try std.testing.expect(!ctx.frame_active);

    // The post-frame APIs are legal exactly where the frame is closed.
    _ = ctx.popupMenu(1, &.{});

    // And the next frame opens cleanly after all of it.
    ctx.beginFrame(800, 600);
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

fn countTextCmds(ctx: *const Context) usize {
    var n: usize = 0;
    for (ctx.draw_list.cmds.items) |cmd| {
        if (cmd == .text) n += 1;
    }
    return n;
}

fn firstText(ctx: *const Context) ?draw.DrawCmd {
    for (ctx.draw_list.cmds.items) |cmd| {
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
    for (ctx.draw_list.cmds.items) |cmd| {
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
    for (ctx.draw_list.cmds.items) |cmd| {
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
    for (ctx.draw_list.cmds.items) |cmd| {
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
    for (ctx.draw_list.cmds.items) |cmd| {
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
    for (ctx.draw_list.cmds.items) |cmd| {
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
    for (ctx.draw_list.cmds.items) |cmd| {
        if (cmd == .text) last = cmd.text.text;
    }
    try std.testing.expect(std.mem.endsWith(u8, last, "..."));
}

test "labelStyled: each tier uses the matching style color and context font" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.beginFrame(400, 200);
    ctx.beginBox(.{ .direction = .column });
    ctx.labelStyled("H", .heading);
    ctx.labelStyled("B", .body);
    ctx.labelStyled("C", .caption);
    ctx.labelStyled("M", .muted);
    ctx.endBox();
    ctx.endFrame();
    var colors: [4]Color = undefined;
    var fonts: [4]?Font = undefined;
    var n: usize = 0;
    for (ctx.draw_list.cmds.items) |cmd| {
        if (cmd != .text) continue;
        colors[n] = cmd.text.color;
        fonts[n] = cmd.text.font;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(ctx.style.heading.color, colors[0]);
    try std.testing.expectEqual(ctx.style.body.color, colors[1]);
    try std.testing.expectEqual(ctx.style.caption.color, colors[2]);
    try std.testing.expectEqual(ctx.style.muted.color, colors[3]);
    try std.testing.expectEqual(ctx.font.ptr, fonts[0].?.ptr);
    try std.testing.expectEqual(ctx.font.ptr, fonts[1].?.ptr);
    try std.testing.expectEqual(ctx.font.ptr, fonts[2].?.ptr);
    try std.testing.expectEqual(ctx.font.ptr, fonts[3].?.ptr);
}

test "labelStyled: a non-null tier font is carried onto the draw command" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.style.heading.font = font_mod.defaultOutlineFont();
    ctx.beginFrame(400, 80);
    ctx.labelStyled("Title", .heading);
    ctx.endFrame();
    const cmd = firstText(&ctx).?.text;
    try std.testing.expect(cmd.font != null);
    try std.testing.expectEqual(ctx.style.heading.font.?.ptr, cmd.font.?.ptr);
}

test "labelStyled: outline default resolves distinct size and weight variants" {
    var ctx = Context.init(std.testing.allocator, font_mod.default_outline_font);
    defer ctx.deinit();
    ctx.beginFrame(800, 200);
    ctx.beginBox(.{ .direction = .column });
    ctx.labelStyled("Heading", .heading);
    ctx.labelStyled("Body", .body);
    ctx.labelStyled("Caption", .caption);
    ctx.labelStyled("Muted", .muted);
    ctx.endBox();
    ctx.endFrame();

    var fonts: [4]Font = undefined;
    var n: usize = 0;
    for (ctx.draw_list.cmds.items) |cmd| {
        if (cmd != .text) continue;
        fonts[n] = cmd.text.font orelse return error.TestUnexpectedResult;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(fonts[0].ptr != fonts[1].ptr);
    try std.testing.expect(fonts[1].ptr != fonts[2].ptr);
    try std.testing.expect(fonts[2].ptr != fonts[3].ptr);
    try std.testing.expect(fonts[0].metrics().line_height >= fonts[1].metrics().line_height);
    try std.testing.expect(fonts[1].metrics().line_height >= fonts[2].metrics().line_height);
    try std.testing.expect(fonts[2].metrics().line_height >= fonts[3].metrics().line_height);
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
    for (ctx.draw_list.cmds.items) |cmd| {
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
