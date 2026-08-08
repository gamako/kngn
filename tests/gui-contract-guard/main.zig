//! Breaks one GUI lifecycle contract on purpose, so a build gate can assert that the check
//! survives optimisation.
//!
//! The unit tests in `libs/gui` cover the paths that keep the contract. They cannot cover the
//! paths that break it: a violation ends the process, and they run in the same one. They also
//! cannot show that a call site *uses* the check — a predicate can be correct and never called.
//! This executable answers both by committing the violation for real, in a build the gate
//! compiles with optimisation on, where `std.debug.assert` would have been removed.
//!
//! The panic handler below reports through an exit code rather than the default abort, because
//! the signal an abort raises differs by platform while an exit code does not.
//!
//! Not a hot path: one violation, then the process ends.

const std = @import("std");
const gui = @import("gui");

/// Exit code the gate expects. Distinct from 1 (a build or usage error) so that a failure to
/// reach the violation at all cannot be mistaken for the violation firing.
const violation_exit_code = 42;

pub const panic = std.debug.FullPanic(struct {
    fn call(msg: []const u8, first_trace_addr: ?usize) noreturn {
        _ = first_trace_addr;
        std.debug.print("contract violation: {s}\n", .{msg});
        std.process.exit(violation_exit_code);
    }
}.call);

const Case = enum {
    /// A widget built with no frame open.
    widget_outside_frame,
    /// A post-frame API called while a frame is open.
    popup_inside_frame,
    /// The other post-frame API — the menu bar dropdown — called while a frame is open.
    menu_inside_frame,
    /// A frame closed with a box still open.
    unclosed_box,
    /// A frame closed with a slider group still open.
    unclosed_slider_group,
    /// A frame opened while one is already open.
    double_begin_frame,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit(gpa);
    _ = args.skip(); // executable path
    const name = args.next() orelse {
        std.debug.print("usage: gui-contract-guard <case>\n", .{});
        std.process.exit(2);
    };
    const case = std.meta.stringToEnum(Case, name) orelse {
        std.debug.print("unknown case: {s}\n", .{name});
        std.process.exit(2);
    };

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    switch (case) {
        .widget_outside_frame => {
            // No beginFrame: the layout tree does not exist yet.
            ctx.label("built with no frame open");
        },
        .popup_inside_frame => {
            ctx.beginFrame(320, 240);
            _ = ctx.popupMenu(1, &.{});
            ctx.endFrame();
        },
        .menu_inside_frame => {
            var menu_state: gui.MenuBarState = .{};
            ctx.beginFrame(320, 240);
            _ = gui.menuBarPopup(&ctx, &.{}, &menu_state);
            ctx.endFrame();
        },
        .unclosed_box => {
            ctx.beginFrame(320, 240);
            ctx.beginBox(.{});
            ctx.endFrame();
        },
        .unclosed_slider_group => {
            ctx.beginFrame(320, 240);
            ctx.beginSliderGroup(.{});
            ctx.endFrame();
        },
        .double_begin_frame => {
            ctx.beginFrame(320, 240);
            ctx.beginFrame(320, 240);
        },
    }

    // Reaching here means the contract check did not fire.
    std.debug.print("no violation detected for case {s}\n", .{@tagName(case)});
    std.process.exit(0);
}
