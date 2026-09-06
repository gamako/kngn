//! Reaches the GUI surface an application needs to bring its own elevation scale.
//!
//! Unlike the other sources here, nothing in this one resolves against a system
//! library: what it guards is **reachability through the package**. A theme's shadow
//! table is described by type names (`Elevation`, `ElevationLevel`, `ElevationLevels`)
//! that only a consumer replacing the table ever writes, so dropping one of them from
//! the umbrella module breaks no build inside this repository — the library reaches
//! them by file, not by import path.
//!
//! The rule the other sources follow applies in its own form here: naming a type
//! proves nothing on its own, because a name that resolves is not a name that works.
//! So this builds a table, hands it to a `Style`, reads it back through the accessor,
//! paints a box with the result, and observes the commands that came out.
//!
//! Runs at gate time only, and in fact never has to run at all: an unreachable name is
//! a build failure, not a runtime one.

const std = @import("std");
const kit = @import("kit");
const gui = kit.gui;

/// One step, written the way an application transcribing a design system's tokens
/// writes it: several layers, in paint order.
const card_step: gui.ElevationLevel = .{ .layers = &.{
    .{ .color = gui.Color.rgba(0x10, 0x10, 0x1C, 0x0F), .offset = .{ .x = 0, .y = 8 }, .blur = 24 },
    .{ .color = gui.Color.rgba(0x10, 0x10, 0x1C, 0x0F), .offset = .{ .x = 0, .y = 1 }, .blur = 2 },
} };

/// The whole scale. Static, because the style borrows it for as long as it is used.
const app_levels: gui.ElevationLevels = .{ .{}, card_step, .{}, .{} };

/// The token group the style holds, named so that dropping it from the umbrella module
/// fails here rather than in an application nobody in this repository builds.
const app_elevation: gui.ElevationTokens = .{ .levels = &app_levels };

pub fn main() !void {
    var style = gui.defaultStyle();
    style.elevation = app_elevation;

    const level: gui.Elevation = .raised;
    const layers: []const gui.BoxShadow = style.shadowsFor(level);

    var dl = gui.DrawList.init(std.heap.page_allocator);
    defer dl.deinit();
    dl.reset(64, 64);
    const options: gui.BoxOptions = .{
        .background = .{ .solid = style.surface.raised },
        .radius = 8,
        .shadows = layers,
    };
    try dl.box(.{ .x = 4, .y = 4, .w = 40, .h = 24 }, options);

    // One command per layer plus the background, or the table never reached the box.
    if (dl.cmds.items.len != layers.len + 1) return error.ElevationDidNotReachTheBox;
}
