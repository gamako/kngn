//! patch macro box の canvas adapter と shared stepgrid の hit-test 契約。

const std = @import("std");
const canvas = @import("canvas.zig");
const stepgrid = @import("gui").stepgrid;

fn asStepgrid(g: canvas.GridGeometry) stepgrid.Geometry {
    return .{
        .origin_x = g.origin_x,
        .origin_y = g.origin_y,
        .cell_w = g.cell_w,
        .cell_h = g.cell_h,
        .step_pitch = g.step_pitch,
        .row_pitch = g.row_pitch,
    };
}

test "patch: box-local macro grid geometry round-trips through stepgrid hit-test" {
    const local_geometry = asStepgrid(canvas.macroGridGeometry(
        .{ .zoom = 1.0 },
        .{ .x = 0, .y = 0 },
    ));

    var row: u8 = 0;
    while (row < 4) : (row += 1) {
        var step: u8 = 0;
        while (step < stepgrid.STEP_COUNT) : (step += 1) {
            const rect = local_geometry.cellRect(row, step);
            const cell = stepgrid.hitTest(
                local_geometry,
                rect.x + rect.w * 0.5,
                rect.y + rect.h * 0.5,
                4,
            ) orelse return error.TestExpectedEqual;
            try std.testing.expectEqual(stepgrid.GridCell{ .row = row, .step = step }, cell);
        }
    }

    // cell 間の horizontal gap は、旧 hitTestGridCell と同様にどのセルにもならない。
    const first = local_geometry.cellRect(0, 0);
    try std.testing.expectEqual(
        @as(?stepgrid.GridCell, null),
        stepgrid.hitTest(local_geometry, first.x + first.w + 0.25, first.y + first.h * 0.5, 4),
    );
}

test "patch: generated three-lane grid hits every clap-row cell" {
    const geometry = asStepgrid(canvas.macroGridGeometry(
        .{ .zoom = 1.0 },
        .{ .x = 40, .y = 330 },
    ));

    var row: u8 = 0;
    while (row < 3) : (row += 1) {
        var step: u8 = 0;
        while (step < stepgrid.STEP_COUNT) : (step += 1) {
            const rect = geometry.cellRect(row, step);
            const cell = stepgrid.hitTest(
                geometry,
                rect.x + rect.w * 0.5,
                rect.y + rect.h * 0.5,
                3,
            ) orelse return error.TestExpectedEqual;
            try std.testing.expectEqual(stepgrid.GridCell{ .row = row, .step = step }, cell);
        }
    }

    const box = canvas.NodeGeom{ .handle = 48, .pos = .{ .x = 40, .y = 330 }, .n_in = 3, .n_out = 3, .grid_rows = 3 };
    const last = geometry.cellRect(2, stepgrid.STEP_COUNT - 1);
    try std.testing.expect(last.y + last.h <= box.pos.y + canvas.nodeSize(box).y);
}
