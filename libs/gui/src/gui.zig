// libs/gui 公開 API root
//
// 使い方（毎フレーム）:
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

pub const BitmapFont = @import("font.zig").BitmapFont;
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
}
