// libs/gui public API root
//
// Per-frame usage (Context + layout):
//   ctx.beginFrame(fb_w, fb_h);
//   // pushEvent → widget (sync hit-test against previous-frame rect) → beginBox/label/endBox
//   ctx.endFrame(); // finalize layout + emit draw cmds + update rect cache
//   gui.render(target, &ctx.draw_list, ctx.font, 1.0);
//
// Low-level DrawList-only use (no layout) is also supported:
//   var dl = gui.DrawList.init(gpa);
//   dl.reset(fb_w, fb_h);
//   try dl.rectFilled(...);
//   gui.render(target, &dl, gui.default_font, 1.0);

pub const Rect = @import("geom.zig").Rect;
pub const Vec2 = @import("geom.zig").Vec2;
pub const RenderTarget = @import("geom.zig").RenderTarget;

pub const Color = @import("color.zig").Color;

pub const DrawCmd = @import("draw.zig").DrawCmd;
pub const DrawList = @import("draw.zig").DrawList;

/// A `DrawList`'s observability pair for the harness `drawlist` custom probe (see
/// docs/harness.md): `drawlistDigest` folds it to one stable-hash-plus-counts line,
/// `drawlistDumpAlloc` renders the full one-line-per-command structure dump.
pub const drawlistDigest = @import("drawlist_probe.zig").digest;
pub const drawlistDumpAlloc = @import("drawlist_probe.zig").dumpAlloc;

pub const Font = @import("font.zig").Font;
pub const Metrics = @import("font.zig").Metrics;
pub const BitmapFont = @import("font.zig").BitmapFont;
pub const default_bitmap_font = @import("font.zig").default_bitmap_font;
/// Default font (shared Font interface value). Pass to Context.init / render.
/// Vtable wrapper around default_bitmap_font (fixed-width 8×16 bitmap for ASCII 32..127).
/// Non-ASCII is a missing glyph (draw skipped; advance is still 8px). No font chain / fallback.
/// measure is codepoint count × 8; drawTo also advances 8px per codepoint (logical widths match.
/// Advance still moves for undrawn glyphs, so ink width may differ).
pub const default_font = @import("font.zig").default_font;
/// Embedded Press Start 2P OutlineFont (lazy init; logical 16px). Distinct from bitmap `default_font`.
pub const defaultOutlineFont = @import("font.zig").defaultOutlineFont;
/// Logical ink height (ascent+descent) and vertically centered y within a row. Also exposed for direct DrawList writing.
pub const inkHeight = @import("font.zig").inkHeight;
pub const fontInkHeight = @import("font.zig").fontInkHeight;
pub const centeredTextY = @import("font.zig").centeredTextY;

pub const render = @import("render.zig").render;

// Input management + ID stack + composition state + Context
pub const InputEvent = @import("input.zig").InputEvent;
pub const Input = @import("input.zig").Input;
pub const MouseButtons = @import("input.zig").MouseButtons;
pub const ModifierFlags = @import("input.zig").ModifierFlags;
pub const Vec2f = @import("input.zig").Vec2f;
pub const CompositionState = @import("input.zig").CompositionState;
/// Key codes and modifier bits this library reacts to, for callers that push events by hand.
pub const key = @import("input.zig").key;
pub const mod = @import("input.zig").mod;

pub const Id = @import("id.zig").Id;
pub const IdStack = @import("id.zig").IdStack;

pub const InteractionState = @import("state.zig").InteractionState;
pub const PerIdState = @import("state.zig").PerIdState;
pub const PerIdStateStore = @import("state.zig").PerIdStateStore;

// Single-line text_edit core.
// TextLayout: mapping among codepoint index (0..count), UTF-8 byte offset, and cumulative logical width.
// buildTextLayout: calls Font.measure per codepoint to build prefix_widths.
// hitTest: returns a codepoint index at the midpoint of each prefix_widths advance (not a byte offset).
pub const TextRange = @import("text_edit.zig").TextRange;
pub const TextLayout = @import("text_edit.zig").TextLayout;
pub const SelectionState = @import("text_edit.zig").SelectionState;
pub const MoveKey = @import("text_edit.zig").MoveKey;
pub const TextBuffer = @import("text_edit.zig").TextBuffer;
pub const CopyRequest = @import("text_edit.zig").CopyRequest;
pub const CopyKind = @import("text_edit.zig").CopyKind;
pub const OrderedTextEvent = @import("input.zig").OrderedTextEvent;
pub const buildTextLayout = @import("text_edit.zig").buildTextLayout;
pub const hitTest = @import("text_edit.zig").hitTest;
pub const byteIndex = @import("text_edit.zig").byteIndex;
pub const wordRange = @import("text_edit.zig").wordRange;

pub const Context = @import("context.zig").Context;
pub const ButtonResult = @import("context.zig").ButtonResult;
pub const buttonBehavior = @import("context.zig").buttonBehavior;
pub const pointHitsVisible = @import("context.zig").pointHitsVisible;
pub const CachedRect = @import("context.zig").CachedRect;

// Flex layout engine
pub const Direction = @import("layout.zig").Direction;
pub const Sizing = @import("layout.zig").Sizing;
pub const Align = @import("layout.zig").Align;
pub const BoxConfig = @import("layout.zig").BoxConfig;
pub const Border = @import("layout.zig").Border;
pub const CustomDrawFn = @import("layout.zig").CustomDrawFn;

// Widget layer. Widget bodies (button / colorSwatch / etc.) are invoked as Context
// methods (e.g. ctx.button("Save"); implementations live in widgets.zig).
pub const Style = @import("style.zig").Style;
pub const defaultStyle = @import("style.zig").defaultStyle;
pub const ButtonOpts = @import("widgets.zig").ButtonOpts;
pub const SwatchOpts = @import("widgets.zig").SwatchOpts;
pub const IconBitmap = @import("widgets.zig").IconBitmap;
pub const SliderI32Opts = @import("widgets.zig").SliderI32Opts;
pub const SliderF32Opts = @import("widgets.zig").SliderF32Opts;
pub const SvSquareOpts = @import("widgets.zig").SvSquareOpts;
pub const HueBarOpts = @import("widgets.zig").HueBarOpts;
pub const ImageBoxOpts = @import("widgets.zig").ImageBoxOpts;
pub const Orient = @import("widgets.zig").Orient;
pub const SplitterOpts = @import("widgets.zig").SplitterOpts;
pub const splitter = @import("widgets.zig").splitter;
pub const ScrollAreaOpts = @import("widgets.zig").ScrollAreaOpts;
pub const SelectableLabelOpts = @import("widgets.zig").SelectableLabelOpts;
pub const SelectableLabelResult = @import("widgets.zig").SelectableLabelResult;
pub const selectableLabel = @import("widgets.zig").selectableLabel;
pub const selectableLabelId = @import("widgets.zig").selectableLabelId;
pub const TextInputOpts = @import("widgets.zig").TextInputOpts;
pub const TextInputResult = @import("widgets.zig").TextInputResult;
pub const textInputId = @import("widgets.zig").textInputId;
// Tabs (selected-section semantics)
pub const TabOpts = @import("widgets.zig").TabOpts;
pub const TabResult = @import("widgets.zig").TabResult;
pub const tabId = @import("widgets.zig").tabId;
// Listbox (single selection + Up/Down keyboard navigation)
pub const ListNav = @import("widgets.zig").ListNav;
pub const ListboxRowOpts = @import("widgets.zig").ListboxRowOpts;
pub const ListboxRowResult = @import("widgets.zig").ListboxRowResult;
pub const pollListNav = @import("widgets.zig").pollListNav;
pub const beginListboxRow = @import("widgets.zig").beginListboxRow;
pub const endListboxRow = @import("widgets.zig").endListboxRow;
// Ellipsis
pub const EllipsisResult = @import("widgets.zig").EllipsisResult;
pub const ellipsizeText = @import("widgets.zig").ellipsizeText;
pub const labelEllipsis = @import("widgets.zig").labelEllipsis;
// Form row
pub const FormRowOpts = @import("widgets.zig").FormRowOpts;
pub const beginFormRow = @import("widgets.zig").beginFormRow;
pub const endFormRow = @import("widgets.zig").endFormRow;

// PanelHost — dock-slot panel system.
pub const PanelHost = @import("panel_host.zig").PanelHost;
pub const Panel = @import("panel_host.zig").Panel;
pub const PanelBuildFn = @import("panel_host.zig").PanelBuildFn;
pub const Slot = @import("panel_host.zig").Slot;
pub const SlotOptions = @import("panel_host.zig").SlotOptions;
pub const Options = @import("panel_host.zig").Options;
pub const Hit = @import("panel_host.zig").Hit;
pub const PersistSlotField = @import("panel_host.zig").PersistSlotField;
pub const PersistPanelField = @import("panel_host.zig").PersistPanelField;
pub const PersistKey = @import("panel_host.zig").PersistKey;
pub const PersistValue = @import("panel_host.zig").PersistValue;
pub const Persistence = @import("panel_host.zig").Persistence;

// 16-step grid (pure geometry/drawing + Flex row widget).
pub const stepgrid = @import("context.zig").stepgrid;

// Menu definitions come from core's type-only module directly. gui does not execute Command;
// it only exposes the same definitions to the UI side as the platform facade (ADR-007 R2).
pub const Command = @import("command_types").Command;
pub const CommandId = @import("command_types").CommandId;
pub const CommandKind = @import("command_types").CommandKind;
pub const ExecutionPolicy = @import("command_types").ExecutionPolicy;
pub const Shortcut = @import("command_types").Shortcut;
// Popup / context menu. Generic primitive that shows a menu at an arbitrary position and
// returns the selection on item click. See the doc comment in popup.zig for usage.
// Usual call site is as Context methods (ctx.openPopup / ctx.closePopup / ctx.hasOpenPopup / ctx.isPopupOpen /
// ctx.popupMenu), same shape as other widgets.
pub const PopupState = @import("popup.zig").PopupState;
pub const PopupItem = @import("popup.zig").PopupItem;
pub const PopupResult = @import("popup.zig").PopupResult;
pub const PopupGeometry = @import("popup.zig").PopupGeometry;
pub const layoutPopup = @import("popup.zig").layoutPopup;
pub const itemRect = @import("popup.zig").itemRect;
pub const hitTestItem = @import("popup.zig").hitTestItem;

// Menu bar / dropdown built from Command definitions.
// gui does not execute Command; it only returns the selected CommandId (owned by the app's dispatchCommand).
pub const MenuBarState = @import("menu.zig").MenuBarState;
pub const MenuBarResult = @import("menu.zig").MenuBarResult;
pub const MENU_BAR_POPUP_ID = @import("menu.zig").MENU_BAR_POPUP_ID;
pub const formatShortcut = @import("menu.zig").formatShortcut;
pub const formatItemLabel = @import("menu.zig").formatItemLabel;
pub const collectMenuTitles = @import("menu.zig").collectMenuTitles;
pub const collectMenuCommands = @import("menu.zig").collectMenuCommands;
pub const menuBar = @import("menu.zig").menuBar;
pub const menuBarPopup = @import("menu.zig").menuBarPopup;

// Collect each file's tests for test-gui.
// A decl reference like `pub const X = @import("f.zig").X` does not pull in f.zig's tests, so
// reference the whole namespace with `_ = @import(...)` to bring the test blocks in.
test {
    _ = @import("geom.zig");
    _ = @import("color.zig");
    _ = @import("draw.zig");
    _ = @import("font.zig");
    _ = @import("render.zig");
    _ = @import("input.zig");
    _ = @import("text_edit.zig");
    _ = @import("id.zig");
    _ = @import("state.zig");
    _ = @import("context.zig");
    _ = @import("layout.zig");
    _ = @import("style.zig");
    _ = @import("widgets.zig");
    _ = @import("popup.zig");
    _ = @import("menu.zig");
    _ = @import("stepgrid.zig");
    _ = @import("panel_host.zig");
}
