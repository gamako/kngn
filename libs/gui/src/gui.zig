// libs/gui 公開 API root
//
// 使い方（毎フレーム、Context + レイアウト）:
//   ctx.beginFrame(fb_w, fb_h);
//   // pushEvent → widget（前フレーム rect で同期 hit-test）→ beginBox/label/endBox
//   ctx.endFrame(); // layout 確定 + draw cmd 発行 + rect キャッシュ更新
//   gui.render(target, &ctx.draw_list, ctx.font);
//
// DrawList 単体（レイアウトなし）の低レベル利用も可:
//   var dl = gui.DrawList.init(gpa);
//   dl.reset(fb_w, fb_h);
//   try dl.rectFilled(...);
//   gui.render(target, &dl, gui.default_font);

pub const Rect = @import("geom.zig").Rect;
pub const Vec2 = @import("geom.zig").Vec2;
pub const RenderTarget = @import("geom.zig").RenderTarget;

pub const Color = @import("color.zig").Color;

pub const DrawCmd = @import("draw.zig").DrawCmd;
pub const DrawList = @import("draw.zig").DrawList;

pub const Font = @import("font.zig").Font;
pub const Metrics = @import("font.zig").Metrics;
pub const BitmapFont = @import("font.zig").BitmapFont;
pub const default_bitmap_font = @import("font.zig").default_bitmap_font;
/// 既定フォント（共通 Font インターフェース値）。Context.init / render に渡す。
/// default_bitmap_font（ASCII 32..127 の 8×16 固定幅ビットマップ）の vtable ラッパ。
/// 非 ASCII は missing glyph（描画スキップ・advance は 8px）。font chain / fallback はない。
/// measure は codepoint 数 × 8、drawTo も codepoint ごとに 8px 進む（logical width は一致。
/// glyph 未描画時も advance は進むため ink 幅とは一致しない）。
pub const default_font = @import("font.zig").default_font;

pub const render = @import("render.zig").render;

// 入力管理 + ID stack + interaction state + Context（TASK-21.2）
pub const InputEvent = @import("input.zig").InputEvent;
pub const Input = @import("input.zig").Input;
pub const MouseButtons = @import("input.zig").MouseButtons;
pub const ModifierFlags = @import("input.zig").ModifierFlags;
pub const Vec2f = @import("input.zig").Vec2f;
pub const CompositionState = @import("input.zig").CompositionState;

pub const Id = @import("id.zig").Id;
pub const IdStack = @import("id.zig").IdStack;

pub const InteractionState = @import("state.zig").InteractionState;
pub const PerIdState = @import("state.zig").PerIdState;
pub const PerIdStateStore = @import("state.zig").PerIdStateStore;

// 単一行 text_edit コア（TASK-113.1 / TASK-132 契約明文化）。
// TextLayout: codepoint index（0..count）と UTF-8 byte offset / 累積 logical width の対応表。
// buildTextLayout: Font.measure を codepoint ごとに呼び prefix_widths を構築する。
// hitTest: prefix_widths の advance 中点で codepoint index を返す（byte offset ではない）。
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

// Flex レイアウトエンジン（TASK-21.4）
pub const Direction = @import("layout.zig").Direction;
pub const Sizing = @import("layout.zig").Sizing;
pub const Align = @import("layout.zig").Align;
pub const BoxConfig = @import("layout.zig").BoxConfig;
pub const Border = @import("layout.zig").Border;
pub const CustomDrawFn = @import("layout.zig").CustomDrawFn;

// widget 層（TASK-21.5）。widget 本体（button / colorSwatch 等）は Context の
// メソッドとして呼ぶ（ctx.button("Save") 等。実装は widgets.zig）。
pub const Style = @import("style.zig").Style;
pub const defaultStyle = @import("style.zig").defaultStyle;
pub const ButtonOpts = @import("widgets.zig").ButtonOpts;
pub const SwatchOpts = @import("widgets.zig").SwatchOpts;
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

// 16-step grid（純幾何/描画 + Flex row widget。TASK-105.1）。
pub const stepgrid = @import("context.zig").stepgrid;

// メニュー定義は core の type-only module を直接参照する。gui は Command を実行せず、
// platform facade と同じ定義を UI 側から見せるだけである（ADR-007 R2）。
pub const Command = @import("command_types").Command;
pub const CommandId = @import("command_types").CommandId;
pub const CommandKind = @import("command_types").CommandKind;
pub const ExecutionPolicy = @import("command_types").ExecutionPolicy;
pub const Shortcut = @import("command_types").Shortcut;
// ポップアップ/コンテキストメニュー（TASK-79.1）。任意座標にメニューを表示し、
// 項目クリックで選択を返す汎用 primitive。使い方は popup.zig の doc comment 参照。
// Context メソッド（ctx.openPopup / ctx.closePopup / ctx.hasOpenPopup / ctx.isPopupOpen /
// ctx.popupMenu）として呼ぶのが通常の使い方（widget と同型）。
pub const PopupState = @import("popup.zig").PopupState;
pub const PopupItem = @import("popup.zig").PopupItem;
pub const PopupResult = @import("popup.zig").PopupResult;
pub const PopupGeometry = @import("popup.zig").PopupGeometry;
pub const layoutPopup = @import("popup.zig").layoutPopup;
pub const itemRect = @import("popup.zig").itemRect;
pub const hitTestItem = @import("popup.zig").hitTestItem;

// Command 定義から生成するメニューバー / ドロップダウン（TASK-97.2）。
// gui は Command を実行せず、選択 CommandId を返すだけ（app の dispatchCommand が所有）。
pub const MenuBarState = @import("menu.zig").MenuBarState;
pub const MenuBarResult = @import("menu.zig").MenuBarResult;
pub const MENU_BAR_POPUP_ID = @import("menu.zig").MENU_BAR_POPUP_ID;
pub const formatShortcut = @import("menu.zig").formatShortcut;
pub const formatItemLabel = @import("menu.zig").formatItemLabel;
pub const collectMenuTitles = @import("menu.zig").collectMenuTitles;
pub const collectMenuCommands = @import("menu.zig").collectMenuCommands;
pub const menuBar = @import("menu.zig").menuBar;
pub const menuBarPopup = @import("menu.zig").menuBarPopup;

// test-gui 用に各ファイルの test を収集する。
// `pub const X = @import("f.zig").X` の decl 参照では f.zig の test は集まらないため、
// namespace 全体を `_ = @import(...)` で参照して test ブロックを取り込む。
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
}
