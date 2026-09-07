//! The screen: one function, one box tree. This is the file to edit.
//!
//! `beginBox` / `endBox` state the structure and a `Sizing` per axis (`.fixed`,
//! `.grow`, `.fit`) states what a resize does to it, so nothing here computes a
//! coordinate. `docs/app-authoring.md` §5 is the reference, and
//! `examples/47_screen_layout` is this shape at full size.
//!
//! Runs every frame: the tree, its layout and its text are rebuilt each frame into
//! a DrawList whose size does not depend on the input. It adds no all-pixel loop
//! (the canvas fill lives in `main.zig`) and no real-time path.

const std = @import("std");
const kit = @import("kit");
const gui = kit.gui;

/// The canvas fills the title bar's button switches between (opaque 0xAARRGGBB).
const default_color: u32 = 0xFF2E3440;
const alt_color: u32 = 0xFF88C0D0;

/// What the screen shows and writes. The GUI holds no application state.
pub const State = struct {
    color: u32 = default_color,
};

/// Build one frame of the screen. Called between `beginFrame` and `endFrame`.
pub fn build(ctx: *gui.Context, state: *State) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
    });

    // A title bar keeps its height at every window size, so it is `.fixed`.
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .height = .{ .fixed = 40 },
        .padding = .{ 0, 12, 0, 12 }, // top, right, bottom, left
        .gap = 12,
        .align_cross = .center,
        .bg = ctx.style.surface.panel,
    });
    ctx.text("kngn template", .{});
    // An empty `.grow` box is how a row splits into two groups: there is no space-between.
    ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .fixed = 1 } });
    ctx.endBox();
    if (ctx.button("Toggle color")) {
        state.color = if (state.color == default_color) alt_color else default_color;
    }
    ctx.endBox();

    // Your content goes in here. Being the only `.grow` child on the column's main
    // axis, it takes every pixel a resize adds or removes; the title bar keeps its 40.
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 12, 12, 12, 12 },
        .align_main = .center,
        .align_cross = .center,
    });
    // A surface of its own, because the canvas behind it is a colour this app chose:
    // the theme's text tokens are contrast-matched to the theme's surfaces, not to it.
    ctx.beginBox(.{
        .padding = .{ 6, 10, 6, 10 },
        .bg = ctx.style.surface.panel,
    });
    var hex: [8]u8 = undefined;
    ctx.text(
        std.fmt.bufPrint(&hex, "#{X:0>6}", .{state.color & 0xFF_FFFF}) catch "",
        .{ .color = ctx.style.text_tokens.subtle },
    );
    ctx.endBox();
    ctx.endBox();

    ctx.endBox();
}
