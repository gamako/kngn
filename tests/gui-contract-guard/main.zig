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
    /// A popup consumer called with no frame open.
    popup_inside_frame,
    /// A menu-bar consumer called with no frame open.
    menu_inside_frame,
    /// A frame closed with a box still open.
    unclosed_box,
    /// A frame closed with a slider group still open.
    unclosed_slider_group,
    /// A frame opened while one is already open.
    double_begin_frame,
    /// A table closed with a table still open.
    unclosed_table,
    /// beginTable while another table is open.
    nested_table,
    /// endTableRow with fewer cells than columns.
    table_cell_count,
    /// h_scroll with a grow column.
    table_h_scroll_grow,
    /// h_scroll without a scroll pointer.
    table_h_scroll_no_scroll,
    /// stretch_cells on a grow-height row.
    table_stretch_grow,
    /// A scrolling table with `.fit` width.
    table_scroll_fit_width,
    /// A scrolling table with `.fit` height.
    table_scroll_fit_height,
    /// Display-only tooltip builder called a prohibited API.
    display_only_button,
    display_only_checkbox,
    display_only_toggle,
    display_only_radio,
    display_only_slider_i32,
    display_only_slider_f32,
    display_only_sv,
    display_only_hue,
    display_only_swatch,
    display_only_icon,
    display_only_selectable,
    display_only_tab,
    display_only_listbox,
    display_only_splitter,
    display_only_collapsible,
    display_only_end_collapsible,
    display_only_menu_bar,
    display_only_virtual_scroll_to_row,
    display_only_begin_table,
    display_only_register_focusable,
    display_only_claim_focus,
    display_only_release_focus,
    display_only_clear_disabled,
    display_only_note_last,
    display_only_begin_disabled,
    display_only_end_disabled,
    display_only_begin_scroll,
    display_only_end_scroll,
    display_only_begin_slider_group,
    display_only_end_slider_group,
    display_only_popup_menu,
    display_only_popup_menu_ex,
    display_only_popup_menu_stacked,
    display_only_dialog,
    display_only_drag_source,
    display_only_drop_target,
    display_only_finish_drag,
    display_only_cancel_drag,
    display_only_text_input,
    display_only_per_id_state,
    display_only_tooltip,
    display_only_tooltip_box,
    display_only_push_event,
    display_only_set_composition,
    display_only_button_behavior,
    tooltip_builder_unclosed_box,
    tooltip_builder_id_stack,
    /// A marker subtree may not access either frame draw-list accessor.
    marker_main_draw_list,
    marker_post_frame_draw_list,
    /// A modal marker must retain geometry for previous-frame input routing.
    modal_layer_without_cache,
    /// Outside dismissal is meaningful only for an input-owning marker.
    none_layer_with_outside_dismiss,
    /// A tooltip subtree may not access either frame draw-list accessor.
    tooltip_main_draw_list,
    tooltip_post_frame_draw_list,
};

fn runDisplayOnly(ctx: *gui.Context, build_fn: gui.TooltipBuildFn) void {
    ctx.beginFrame(320, 240);
    // First frame: empty rect cache. Arm hover so the builder actually runs.
    ctx.tooltip_last_id = 1;
    ctx.tooltip_last_rect = .{ .x = 8, .y = 8, .w = 40, .h = 16 };
    ctx.tooltip_last_hovered = true;
    ctx.tooltip_hover_id = 1;
    ctx.tooltip_hover_rect = ctx.tooltip_last_rect;
    ctx.tooltip_hover_start_s = ctx.now() - gui.Context.tooltip_delay_s;
    var dummy: u8 = 0;
    ctx.tooltipBox(build_fn, &dummy);
    ctx.endFrame();
}

fn runMarkerMainDrawList(ctx: *gui.Context) void {
    ctx.beginFrame(320, 240);
    ctx.beginBox(.{
        .layer = &.{ .key = .{ .value = 1 }, .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } } },
    });
    _ = ctx.mainDrawList();
}

fn runMarkerPostFrameDrawList(ctx: *gui.Context) void {
    ctx.beginFrame(320, 240);
    ctx.beginBox(.{
        .layer = &.{ .key = .{ .value = 1 }, .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } } },
    });
    _ = ctx.postFrameDrawList();
}

fn runModalLayerWithoutCache(ctx: *gui.Context) void {
    ctx.beginFrame(320, 240);
    ctx.beginBox(.{
        .layer = &.{
            .key = .{ .value = 2 },
            .cache = false,
            .input = .modal,
            .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } },
        },
    });
}

fn runNoneLayerWithOutsideDismiss(ctx: *gui.Context) void {
    ctx.beginFrame(320, 240);
    ctx.beginBox(.{
        .layer = &.{
            .key = .{ .value = 3 },
            .dismiss_on_outside = true,
            .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } },
        },
    });
}

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
            var state: gui.PopupState = .{
                .key = .{ .value = 11 },
                .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } },
                .open = true,
            };
            _ = ctx.popupMenu(&state, &.{.{ .label = "item" }});
        },
        .menu_inside_frame => {
            var menu_state: gui.MenuBarState = .{};
            _ = gui.menuBarPopup(&ctx, &.{}, &menu_state);
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
        .unclosed_table => {
            ctx.beginFrame(320, 240);
            ctx.beginTable(1, &[_]gui.TableCol{}, .{});
            ctx.endFrame();
        },
        .nested_table => {
            ctx.beginFrame(320, 240);
            ctx.beginTable(1, &[_]gui.TableCol{}, .{});
            ctx.beginTable(2, &[_]gui.TableCol{}, .{});
            ctx.endTable();
            ctx.endTable();
            ctx.endFrame();
        },
        .table_cell_count => {
            const cols = [_]gui.TableCol{.{ .width = .{ .fixed = 40 } }};
            ctx.beginFrame(320, 240);
            ctx.beginTable(1, &cols, .{});
            ctx.beginTableRow(.{});
            _ = ctx.endTableRow();
            ctx.endTable();
            ctx.endFrame();
        },
        .table_h_scroll_grow => {
            var scroll: gui.Vec2f = .{};
            const cols = [_]gui.TableCol{.{ .width = .{ .grow = 1 } }};
            ctx.beginFrame(320, 240);
            ctx.beginTable(1, &cols, .{ .scroll = &scroll, .h_scroll = true });
            ctx.endTable();
            ctx.endFrame();
        },
        .table_h_scroll_no_scroll => {
            const cols = [_]gui.TableCol{.{ .width = .{ .fixed = 40 } }};
            ctx.beginFrame(320, 240);
            ctx.beginTable(1, &cols, .{ .h_scroll = true });
            ctx.endTable();
            ctx.endFrame();
        },
        .table_stretch_grow => {
            const cols = [_]gui.TableCol{.{ .width = .{ .fixed = 40 } }};
            ctx.beginFrame(320, 240);
            ctx.beginTable(1, &cols, .{ .stretch_cells = true });
            ctx.beginTableRow(.{ .height = .{ .grow = 1 } });
            ctx.beginTableCell();
            ctx.endTableCell();
            _ = ctx.endTableRow();
            ctx.endTable();
            ctx.endFrame();
        },
        .table_scroll_fit_width => {
            var scroll: gui.Vec2f = .{};
            const cols = [_]gui.TableCol{.{ .width = .{ .fixed = 40 } }};
            ctx.beginFrame(320, 240);
            ctx.beginTable(1, &cols, .{
                .width = .fit,
                .height = .{ .grow = 1 },
                .scroll = &scroll,
            });
            ctx.endTable();
            ctx.endFrame();
        },
        .table_scroll_fit_height => {
            var scroll: gui.Vec2f = .{};
            const cols = [_]gui.TableCol{.{ .width = .{ .fixed = 40 } }};
            ctx.beginFrame(320, 240);
            ctx.beginTable(1, &cols, .{
                .width = .{ .grow = 1 },
                .height = .fit,
                .scroll = &scroll,
            });
            ctx.endTable();
            ctx.endFrame();
        },
        .display_only_button => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.button("x");
            }
        }.build),
        .display_only_checkbox => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var v = false;
                _ = c.checkbox("x", &v);
            }
        }.build),
        .display_only_toggle => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var v = false;
                _ = c.toggle("x", &v);
            }
        }.build),
        .display_only_radio => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.radio("x", false);
            }
        }.build),
        .display_only_slider_i32 => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var v: i32 = 0;
                _ = c.sliderI32("x", &v, .{ .min = 0, .max = 10 });
            }
        }.build),
        .display_only_slider_f32 => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var v: f32 = 0;
                _ = c.sliderF32("x", &v, .{ .min = 0, .max = 1 });
            }
        }.build),
        .display_only_sv => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var s: f32 = 0.5;
                var v: f32 = 0.5;
                _ = c.svSquare("x", 0, &s, &v, .{});
            }
        }.build),
        .display_only_hue => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var h: f32 = 0;
                _ = c.hueBar("x", &h, .{});
            }
        }.build),
        .display_only_swatch => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.colorSwatch(gui.Color.rgba(0, 0, 0, 0xFF), false);
            }
        }.build),
        .display_only_icon => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                const icon = [_]u16{0} ** 16;
                _ = c.iconButton(&icon, false);
            }
        }.build),
        .display_only_selectable => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.selectableLabel("x", .{});
            }
        }.build),
        .display_only_tab => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.tabId(2, "x", false, .{});
            }
        }.build),
        .display_only_listbox => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.beginListboxRow(2, false, .{});
            }
        }.build),
        .display_only_splitter => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var size: i32 = 40;
                _ = c.splitter(2, .vertical, &size, .{});
            }
        }.build),
        .display_only_collapsible => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var open = false;
                _ = c.beginCollapsible(2, "x", &open);
            }
        }.build),
        .display_only_end_collapsible => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.endCollapsible();
            }
        }.build),
        .display_only_menu_bar => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var state: gui.MenuBarState = .{};
                gui.menuBar(c, &.{}, &state);
            }
        }.build),
        .display_only_virtual_scroll_to_row => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var scroll: gui.Vec2f = .{};
                c.virtualScrollToRow(2, &scroll, .{ .row_height = 16, .row_count = 0 }, 0);
            }
        }.build),
        .display_only_begin_table => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.beginTable(2, &[_]gui.TableCol{}, .{});
            }
        }.build),
        .display_only_register_focusable => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.registerFocusable(2);
            }
        }.build),
        .display_only_claim_focus => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.claimFocus(2);
            }
        }.build),
        .display_only_release_focus => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.releaseFocus();
            }
        }.build),
        .display_only_clear_disabled => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.clearDisabledInteraction(2);
            }
        }.build),
        .display_only_note_last => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.noteLastInteractive(2, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, false);
            }
        }.build),
        .display_only_begin_disabled => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.beginDisabled();
            }
        }.build),
        .display_only_end_disabled => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.endDisabled();
            }
        }.build),
        .display_only_begin_scroll => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var scroll: gui.Vec2f = .{};
                c.beginScrollArea(2, &scroll, .{});
            }
        }.build),
        .display_only_end_scroll => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.endScrollArea();
            }
        }.build),
        .display_only_begin_slider_group => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.beginSliderGroup(.{});
            }
        }.build),
        .display_only_end_slider_group => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.endSliderGroup();
            }
        }.build),
        .display_only_popup_menu => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var state: gui.PopupState = .{
                    .key = .{ .value = 12 },
                    .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } },
                    .open = true,
                };
                _ = c.popupMenu(&state, &.{.{ .label = "item" }});
            }
        }.build),
        .display_only_popup_menu_ex => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var state: gui.PopupState = .{
                    .key = .{ .value = 13 },
                    .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } },
                    .open = true,
                };
                _ = c.popupMenuEx(&state, &.{.{ .label = "item" }}, .{});
            }
        }.build),
        .display_only_popup_menu_stacked => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var state: gui.PopupState = .{
                    .key = .{ .value = 14 },
                    .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } },
                    .open = true,
                };
                _ = c.popupMenuStacked(&state, &.{.{ .label = "item" }}, .{});
            }
        }.build),
        .display_only_dialog => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var state: gui.DialogState = .{
                    .popup = .{
                        .key = .{ .value = 15 },
                        .placement = .{ .source = .{ .point = .{ .x = 0, .y = 0 } } },
                        .open = true,
                    },
                    .options = .{ .title = "title", .body = "body", .actions = &.{.{ .label = "OK" }} },
                };
                _ = c.dialog(&state);
            }
        }.build),
        .display_only_drag_source => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.dragSource(2, gui.DragPayload.fromValue(u8, 1, 0));
            }
        }.build),
        .display_only_drop_target => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.dropTarget(2, true);
            }
        }.build),
        .display_only_finish_drag => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.finishDrag();
            }
        }.build),
        .display_only_cancel_drag => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.cancelDrag();
            }
        }.build),
        .display_only_text_input => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                var buf = gui.TextBuffer.init(c.gpa, "") catch @panic("oom");
                defer buf.deinit();
                _ = c.textInputId(2, &buf, .{});
            }
        }.build),
        .display_only_per_id_state => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.perIdState(2);
            }
        }.build),
        .display_only_tooltip => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.tooltip("nested");
            }
        }.build),
        .display_only_tooltip_box => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.tooltipBox(struct {
                    fn inner(_: *anyopaque, inner_ctx: *gui.Context) void {
                        inner_ctx.label("inner");
                    }
                }.inner, undefined);
            }
        }.build),
        .display_only_push_event => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.pushEvent(.{ .mouse_move = .{ .x = 0, .y = 0, .modifiers = 0 } });
            }
        }.build),
        .display_only_set_composition => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.setComposition(.{});
            }
        }.build),
        .display_only_button_behavior => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = gui.buttonBehavior(c, 2, .{ .x = 0, .y = 0, .w = 8, .h = 8 }, .{ .x = 0, .y = 0, .w = 320, .h = 240 });
            }
        }.build),
        .tooltip_builder_unclosed_box => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.beginBox(.{});
            }
        }.build),
        .tooltip_builder_id_stack => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                c.id_stack.push("x");
            }
        }.build),
        .marker_main_draw_list => runMarkerMainDrawList(&ctx),
        .marker_post_frame_draw_list => runMarkerPostFrameDrawList(&ctx),
        .modal_layer_without_cache => runModalLayerWithoutCache(&ctx),
        .none_layer_with_outside_dismiss => runNoneLayerWithOutsideDismiss(&ctx),
        .tooltip_main_draw_list => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.mainDrawList();
            }
        }.build),
        .tooltip_post_frame_draw_list => runDisplayOnly(&ctx, struct {
            fn build(_: *anyopaque, c: *gui.Context) void {
                _ = c.postFrameDrawList();
            }
        }.build),
    }

    // Reaching here means the contract check did not fire.
    std.debug.print("no violation detected for case {s}\n", .{@tagName(case)});
    std.process.exit(0);
}
