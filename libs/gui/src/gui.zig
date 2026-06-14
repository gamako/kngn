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
pub const default_font = @import("font.zig").default_font;

pub const render = @import("render.zig").render;

// 入力管理 + ID stack + interaction state + Context（TASK-21.2）
pub const InputEvent = @import("input.zig").InputEvent;
pub const Input = @import("input.zig").Input;
pub const MouseButtons = @import("input.zig").MouseButtons;
pub const ModifierFlags = @import("input.zig").ModifierFlags;
pub const Vec2f = @import("input.zig").Vec2f;

pub const Id = @import("id.zig").Id;
pub const IdStack = @import("id.zig").IdStack;

pub const InteractionState = @import("state.zig").InteractionState;

pub const Context = @import("context.zig").Context;
pub const ButtonResult = @import("context.zig").ButtonResult;
pub const buttonBehavior = @import("context.zig").buttonBehavior;
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
    _ = @import("id.zig");
    _ = @import("state.zig");
    _ = @import("context.zig");
    _ = @import("layout.zig");
    _ = @import("style.zig");
    _ = @import("widgets.zig");
}
