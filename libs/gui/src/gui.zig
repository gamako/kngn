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
