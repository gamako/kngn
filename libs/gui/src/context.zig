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
//   widget calls: sync hit-test against the previous-frame rect_cache (never the layout rects still under construction)
//   endFrame():      measure → place → rect_cache.clearRetainingCapacity → updateRectCache
//                    → emitNode (emit draw cmds) → frame_active=false
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
//   - A node's own clip_children applies to its children, not itself.
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
const style_mod = @import("style.zig");
// Mutual import with widgets.zig (widgets take *Context; Zig import cycles are legal).
// Decl aliases inside the Context struct provide `ctx.button(...)` method syntax.
const widgets = @import("widgets.zig");
// popup.zig uses the same mutual-import pattern.
const popup_mod = @import("popup.zig");
const stepgrid_mod = @import("stepgrid.zig");
// dnd.zig uses the same mutual-import pattern (Context.drag is declared here; the state machine lives there).
const dnd_mod = @import("dnd.zig");

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
pub const CachedRect = struct { rect: Rect, clip: Rect, measured_w: i32 = 0, measured_h: i32 = 0 };

/// Internal state carried across a scroll area's begin→end. begin computes from the previous-frame cache,
/// pushes onto scroll_stack; end pops and builds the scrollbar.
/// Wheel is not applied in begin; it is consumed/propagated in end (LIFO = innermost first).
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

pub const Context = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    input: Input,
    id_stack: IdStack,
    state: InteractionState = .{},
    per_id_state: state_mod.PerIdStateStore = .{},
    draw_list: DrawList,
    font: Font,
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
    /// Unconsumed wheel delta for the frame (seeded from input.scroll_delta at the first endScrollArea).
    /// Each ScrollArea consumes only what it could move; remainder at an edge propagates outward.
    wheel_remaining: Vec2f = .{},
    wheel_remaining_seeded: bool = false,
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
    /// Whether tooltip() refreshed the hover target this frame (suppresses unbuilt stale overlays).
    tooltip_hover_refreshed: bool = false,
    /// Last interactive widget (updated by behaviorFromCache; frame-local).
    tooltip_last_id: Id = 0,
    tooltip_last_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    tooltip_last_hovered: bool = false,
    /// Candidate emitted at this frame's endFrame (text on the frame arena; null if not yet due).
    tooltip_candidate_text: ?[]const u8 = null,
    tooltip_candidate_anchor: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Frame-local IME composition (preedit) state. Cleared in beginFrame;
    /// the app sets it every frame via setComposition before widget calls.
    composition: input_mod.CompositionState = .{},
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
            .style = style_mod.defaultStyle(),
        };
    }

    pub fn deinit(self: *Context) void {
        self.rect_cache.deinit(self.gpa);
        self.per_id_state.deinit(self.gpa);
        self.focus_order.deinit(self.gpa);
        self.scroll_stack.deinit(self.gpa);
        self.draw_list.deinit();
        self.id_stack.deinit();
        self.input.deinit();
        self.arena.deinit();
    }

    /// Arena allocator (for cmd text/image payloads). Reset on the next beginFrame.
    pub fn allocator(self: *Context) Allocator {
        return self.arena.allocator();
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
        std.debug.assert(!self.frame_active);
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
        // tooltip frame-local (continuous-hover id/start/rect persist across frames)
        self.tooltip_last_id = 0;
        self.tooltip_last_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        self.tooltip_last_hovered = false;
        self.tooltip_hover_refreshed = false;
        self.tooltip_candidate_text = null;
        self.tooltip_candidate_anchor = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        self.drag_submitted_this_frame = false;
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
    }

    pub fn endFrame(self: *Context) void {
        std.debug.assert(self.frame_active);
        // Every beginDisabled needs a matching endDisabled within the same frame (immediate-mode
        // begin/end nesting rule, the same contract beginCollapsible's body depth follows).
        std.debug.assert(self.disabled_depth == 0);
        const root = self.layout_root.?;
        // Detect beginBox / endBox mismatches
        std.debug.assert(self.layout_current == root);
        // Frames that never use the layout API (empty root) skip layout / emit / cache update
        // entirely: compatible with manual DrawList use (examples 08/09). rect_cache keeps the previous values.
        if (root.first_child != null) {
            layout.measure(root, self.font);
            const screen_rect = Rect{ .x = 0, .y = 0, .w = self.screen_w, .h = self.screen_h };
            layout.place(root, screen_rect);
            self.rect_cache.clearRetainingCapacity();
            self.updateRectCache(root, screen_rect);
            self.emitNode(root);
        }
        // tooltip overlay: after layout UI, before frame_active=false (below popupMenu; popup runs after endFrame).
        if (self.tooltip_candidate_text) |text| {
            popup_mod.drawTooltipOverlay(self, text, self.tooltip_candidate_anchor);
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

    pub fn pushEvent(self: *Context, ev: InputEvent) void {
        std.debug.assert(self.frame_active);
        self.input.pushEvent(ev);
    }

    /// Set frame-local IME composition state. `text` is a borrowed slice owned by the caller
    /// (valid through endFrame drawing). Does not accept platform types (ADR-007).
    pub fn setComposition(self: *Context, state: input_mod.CompositionState) void {
        std.debug.assert(self.frame_active);
        self.composition = state;
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
        std.debug.assert(self.frame_active);
        self.disabled_depth += 1;
    }

    /// Leave a disabled scope opened by `beginDisabled`.
    pub fn endDisabled(self: *Context) void {
        std.debug.assert(self.frame_active);
        std.debug.assert(self.disabled_depth > 0);
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
        std.debug.assert(self.frame_active);
        if (id == 0) return false;
        self.state.focused_id = id;
        self.state.focus_visible = false;
        self.state.focus_claimed_this_frame = true;
        return true;
    }

    /// Clear the current keyboard focus. Actual outside-click clear happens in endFrame when no
    /// widget claimed focus this frame.
    pub fn releaseFocus(self: *Context) void {
        std.debug.assert(self.frame_active);
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
        std.debug.assert(self.frame_active);
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
    /// Even without a rect cache yet, record hovered=false so tooltip() can no-op.
    pub fn noteLastInteractive(self: *Context, id: Id, rect: Rect, hovered: bool) void {
        std.debug.assert(self.frame_active);
        self.tooltip_last_id = id;
        self.tooltip_last_rect = rect;
        self.tooltip_last_hovered = hovered;
    }

    /// Attach a tooltip to the interactive widget just evaluated.
    /// No-op if not hovered this frame. When the same id+rect has been continuous for >= `tooltip_delay_s`,
    /// raise an overlay candidate at the end of endFrame. text is duped onto the frame arena.
    pub fn tooltip(self: *Context, text: []const u8) void {
        std.debug.assert(self.frame_active);
        if (!self.tooltip_last_hovered or self.tooltip_last_id == 0) return;

        const id = self.tooltip_last_id;
        const rect = self.tooltip_last_rect;
        if (id != self.tooltip_hover_id or !tooltipRectEq(rect, self.tooltip_hover_rect)) {
            self.tooltip_hover_id = id;
            self.tooltip_hover_rect = rect;
            self.tooltip_hover_start_s = self.now();
        }
        self.tooltip_hover_refreshed = true;

        if (self.now() - self.tooltip_hover_start_s < tooltip_delay_s) return;

        const dup = self.allocator().dupe(u8, text) catch @panic("tooltip: OOM");
        self.tooltip_candidate_text = dup;
        self.tooltip_candidate_anchor = rect;
    }

    pub fn perIdState(self: *Context, id: Id) *state_mod.PerIdState {
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
        std.debug.assert(self.frame_active);
        layout.assertSizingValid(cfg.width);
        layout.assertSizingValid(cfg.height);
        const parent = self.layout_current.?;
        const node = self.allocator().create(layout.Node) catch @panic("Context.beginBox: OOM");
        node.* = .{
            .id = if (cfg.id != 0) cfg.id else id_mod.hashInt(parent.id, parent.child_count),
            .cfg = cfg,
        };
        layout.appendChild(parent, node);
        self.layout_current = node;
    }

    pub fn endBox(self: *Context) void {
        std.debug.assert(self.frame_active);
        const cur = self.layout_current.?;
        // Trying to pop the root = beginBox / endBox imbalance
        std.debug.assert(cur.parent != null);
        self.layout_current = cur.parent;
    }

    /// text leaf (default color = style.text). str is duped onto the arena, so it does not
    /// depend on the caller buffer's lifetime.
    pub fn label(self: *Context, str: []const u8) void {
        self.labelEx(str, self.style.text);
    }

    pub fn labelEx(self: *Context, str: []const u8, col: Color) void {
        std.debug.assert(self.frame_active);
        const dup = self.allocator().dupe(u8, str) catch @panic("Context.labelEx: OOM");
        self.addLeaf(.{ .text = .{ .str = dup, .color = col, .font = null } });
    }

    /// custom leaf. size is used as the measure result; draw_fn is called with the final rect
    /// after endFrame finalizes layout (DrawList OOM is catch @panic inside the callback).
    pub fn custom(self: *Context, size: Vec2, draw_fn: layout.CustomDrawFn, ctx_ptr: *anyopaque) void {
        std.debug.assert(self.frame_active);
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

    /// Previous-frame measured size of an explicit-ID node (natural size from layout.measure).
    /// Used for scroll clamping etc. Same previous-frame sync contract as getNodeRect.
    /// null on first frame / auto ID / unknown ID / 0.
    pub fn getNodeMeasured(self: *const Context, id: Id) ?Vec2 {
        if (id == 0) return null;
        const entry = self.rect_cache.get(id) orelse return null;
        return .{ .x = entry.measured_w, .y = entry.measured_h };
    }

    fn addLeaf(self: *Context, leaf: layout.LeafKind) void {
        const parent = self.layout_current.?;
        const node = self.allocator().create(layout.Node) catch @panic("Context.addLeaf: OOM");
        node.* = .{
            .id = id_mod.hashInt(parent.id, parent.child_count),
            .leaf = leaf,
        };
        layout.appendChild(parent, node);
    }

    /// Register {rect, clip, measured} for an explicit-ID node (pre-order DFS).
    /// Called only after endFrame's measure/place; not used for hit-test during this frame's widget calls.
    ///
    /// `clip` arg = ancestor-derived effective clip (used for this node's draw and hit-test).
    /// Clip passed to children:
    ///   - `clip_children=true`  → `intersect(clip, node.rect)` (outside parent rect: invisible / not hittable)
    ///   - `clip_children=false` → `clip` unchanged (overflow draw/hit allowed; even with a zero-size parent,
    ///     children can hit if inside the ancestor clip)
    /// Same definition as `emitNode`'s pushClip bounds (cached clip ↔ draw clip correspondence).
    /// measured_w/h are layout.measure results (natural size for scroll clamp etc.).
    /// Duplicate explicit IDs in the same frame are a contract violation (Debug assert; Release last-wins overwrite,
    /// but callers must not use duplicate IDs).
    fn updateRectCache(self: *Context, node: *const layout.Node, clip: Rect) void {
        if (node.cfg.id != 0) {
            const gop = self.rect_cache.getOrPut(self.gpa, node.cfg.id) catch
                @panic("Context.endFrame: OOM");
            // Duplicate explicit IDs in the same frame are a contract violation (last-wins overwrite breaks hit-test)
            std.debug.assert(!gop.found_existing);
            gop.value_ptr.* = .{ .rect = node.rect, .clip = clip, .measured_w = node.measured_w, .measured_h = node.measured_h };
        }
        const child_clip = if (node.cfg.clip_children) Rect.intersect(clip, node.rect) else clip;
        var it = node.first_child;
        while (it) |c| : (it = c.next_sibling) self.updateRectCache(c, child_clip);
    }

    /// Emit draw cmds (pre-order DFS): bg → (pushClip(node.rect) if clip_children) → children / leaf →
    /// popClip → border.
    /// `pushClip(node.rect)` intersects with the ancestor clip in draw_list, so the baked clip matches
    /// the `child_clip = intersect(ancestor, node.rect)` that `updateRectCache` passes to children.
    /// border is emitted after popClip (= ancestor clip) so the frame sits on top of children.
    fn emitNode(self: *Context, node: *const layout.Node) void {
        if (node.leaf) |leaf| {
            switch (leaf) {
                .text => |t| self.draw_list.textEx(
                    .{ .x = node.rect.x, .y = node.rect.y },
                    t.str,
                    t.color,
                    t.font,
                ) catch @panic("Context.endFrame: OOM"),
                .custom => |c| c.draw_fn(c.ctx, &self.draw_list, node.rect),
            }
            return;
        }
        if (node.cfg.bg) |bg| {
            self.draw_list.rectFilled(node.rect, bg) catch @panic("Context.endFrame: OOM");
        }
        if (node.cfg.clip_children) {
            self.draw_list.pushClip(node.rect) catch @panic("Context.endFrame: OOM");
        }
        var it = node.first_child;
        while (it) |c| : (it = c.next_sibling) self.emitNode(c);
        if (node.cfg.clip_children) self.draw_list.popClip();
        if (node.cfg.border) |b| {
            self.draw_list.rectOutline(node.rect, b.color, b.thickness) catch
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
            self.draw_list.rectOutline(node.rect, self.style.focus_ring, self.style.focus_ring_thickness) catch
                @panic("Context.endFrame: OOM");
        }
    }
};

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
    std.debug.assert(ctx.frame_active);
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
    if (ctx.state.active_id == id) {
        result.held = true;
        ctx.state.active_submitted = true; // Anti-stick: mark evaluated this frame
        if (ctx.input.mouse_released.left) {
            if (hovered_now) result.clicked = true;
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
