//! Canvas grid adapter for the patch macro box / standalone step_seq and the shared stepgrid's hit-test contract.

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
    const local_geometry = asStepgrid(canvas.gridGeometry(
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

    // The horizontal gap between cells doesn't belong to any cell, same as the former hitTestGridCell.
    const first = local_geometry.cellRect(0, 0);
    try std.testing.expectEqual(
        @as(?stepgrid.GridCell, null),
        stepgrid.hitTest(local_geometry, first.x + first.w + 0.25, first.y + first.h * 0.5, 4),
    );
}

test "patch: generated three-lane grid hits every clap-row cell" {
    const geometry = asStepgrid(canvas.gridGeometry(
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

test "patch: 1-row inline grid hits 16 cells as row 0; row 1 is out of range" {
    const box_pos = canvas.Vec2f{ .x = 160, .y = 470 };
    const geometry = asStepgrid(canvas.gridGeometry(.{ .zoom = 1.0 }, box_pos));
    const clickable_rows: u8 = 1; // drum standalone

    var step: u8 = 0;
    while (step < stepgrid.STEP_COUNT) : (step += 1) {
        const rect = geometry.cellRect(0, step);
        const cell = stepgrid.hitTest(
            geometry,
            rect.x + rect.w * 0.5,
            rect.y + rect.h * 0.5,
            clickable_rows,
        ) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(stepgrid.GridCell{ .row = 0, .step = step }, cell);
    }

    // Row 1 is out of scope when clickable_rows=1
    const row1 = geometry.cellRect(1, 0);
    try std.testing.expectEqual(
        @as(?stepgrid.GridCell, null),
        stepgrid.hitTest(geometry, row1.x + row1.w * 0.5, row1.y + row1.h * 0.5, clickable_rows),
    );
}

test "patch: 4-row inline grid hits all 16x4 cell centers" {
    const box_pos = canvas.Vec2f{ .x = 200, .y = 100 };
    const geometry = asStepgrid(canvas.gridGeometry(.{ .zoom = 1.0 }, box_pos));

    var row: u8 = 0;
    while (row < 4) : (row += 1) {
        var step: u8 = 0;
        while (step < stepgrid.STEP_COUNT) : (step += 1) {
            const rect = geometry.cellRect(row, step);
            const cell = stepgrid.hitTest(
                geometry,
                rect.x + rect.w * 0.5,
                rect.y + rect.h * 0.5,
                4,
            ) orelse return error.TestExpectedEqual;
            try std.testing.expectEqual(stepgrid.GridCell{ .row = row, .step = step }, cell);
        }
    }
}

test "patch: bass clickable rows=3 excludes pitch row from hit-test" {
    const geometry = asStepgrid(canvas.gridGeometry(
        .{ .zoom = 1.0 },
        .{ .x = 0, .y = 0 },
    ));
    const clickable_rows: u8 = 3; // on/accent/slide only

    var row: u8 = 0;
    while (row < 3) : (row += 1) {
        const rect = geometry.cellRect(row, 5);
        const cell = stepgrid.hitTest(
            geometry,
            rect.x + rect.w * 0.5,
            rect.y + rect.h * 0.5,
            clickable_rows,
        ) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(stepgrid.GridCell{ .row = row, .step = 5 }, cell);
    }

    const pitch = geometry.cellRect(3, 5);
    try std.testing.expectEqual(
        @as(?stepgrid.GridCell, null),
        stepgrid.hitTest(geometry, pitch.x + pitch.w * 0.5, pitch.y + pitch.h * 0.5, clickable_rows),
    );
}

test "patch: zoom keeps world-to-screen cell centers on same row/step" {
    const box_pos = canvas.Vec2f{ .x = 160, .y = 470 };
    const cam = canvas.Camera{ .pan = .{ .x = 0, .y = 0 }, .zoom = 2.0 };
    const geometry = asStepgrid(canvas.gridGeometry(cam, box_pos));

    var row: u8 = 0;
    while (row < 2) : (row += 1) {
        var step: u8 = 0;
        while (step < stepgrid.STEP_COUNT) : (step += 1) {
            const rect = geometry.cellRect(row, step);
            const cell = stepgrid.hitTest(
                geometry,
                rect.x + rect.w * 0.5,
                rect.y + rect.h * 0.5,
                2,
            ) orelse return error.TestExpectedEqual;
            try std.testing.expectEqual(stepgrid.GridCell{ .row = row, .step = step }, cell);
        }
    }
}

test "patch: pan+zoom leaves inter-cell gap and outside-grid as null" {
    const box_pos = canvas.Vec2f{ .x = 40, .y = 330 };
    const cam = canvas.Camera{ .pan = .{ .x = 25, .y = -10 }, .zoom = 1.5 };
    const geometry = asStepgrid(canvas.gridGeometry(cam, box_pos));

    const first = geometry.cellRect(0, 0);
    // horizontal gap between step 0 and 1
    try std.testing.expectEqual(
        @as(?stepgrid.GridCell, null),
        stepgrid.hitTest(geometry, first.x + first.w + 0.25 * cam.zoom, first.y + first.h * 0.5, 3),
    );
    // above grid origin
    try std.testing.expectEqual(
        @as(?stepgrid.GridCell, null),
        stepgrid.hitTest(geometry, first.x + first.w * 0.5, first.y - 1.0, 3),
    );
    // left of grid
    try std.testing.expectEqual(
        @as(?stepgrid.GridCell, null),
        stepgrid.hitTest(geometry, first.x - 1.0, first.y + first.h * 0.5, 3),
    );
    // valid cell still hits
    const cell = stepgrid.hitTest(
        geometry,
        first.x + first.w * 0.5,
        first.y + first.h * 0.5,
        3,
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(stepgrid.GridCell{ .row = 0, .step = 0 }, cell);
}

test "macro evolve/lock toggle geometry sits above step grid" {
    const e = canvas.macroEvolveToggleRect();
    try std.testing.expect(canvas.macroToggleAboveGrid(e));
    var lane: u8 = 0;
    while (lane < 3) : (lane += 1) {
        const lr = canvas.macroLockToggleRect(lane);
        try std.testing.expect(canvas.macroToggleAboveGrid(lr));
        // lock sits to the right of evolve
        try std.testing.expect(lr.x >= e.x + e.w);
    }
    // The collapse-toggle area (right edge) and the evolve/lock band don't overlap
    const collapse_x = canvas.NODE_W - canvas.TOGGLE_SIZE - canvas.TOGGLE_MARGIN;
    try std.testing.expect(canvas.macroLockToggleRect(2).x + canvas.MACRO_MUT_TOGGLE_W < collapse_x);
}

test "macro toggle rects do not collide with step-grid cells" {
    const geometry = asStepgrid(canvas.gridGeometry(.{ .zoom = 1.0 }, .{ .x = 0, .y = 0 }));
    const e = canvas.macroEvolveToggleRect();
    // The toggle's center doesn't fall inside the clickable grid
    try std.testing.expectEqual(
        @as(?stepgrid.GridCell, null),
        stepgrid.hitTest(geometry, e.x + e.w * 0.5, e.y + e.h * 0.5, 3),
    );
    var lane: u8 = 0;
    while (lane < 3) : (lane += 1) {
        const lr = canvas.macroLockToggleRect(lane);
        try std.testing.expectEqual(
            @as(?stepgrid.GridCell, null),
            stepgrid.hitTest(geometry, lr.x + lr.w * 0.5, lr.y + lr.h * 0.5, 3),
        );
    }
    // The grid cell's center is outside the toggle rect
    const cell0 = geometry.cellRect(0, 0);
    const cx = cell0.x + cell0.w * 0.5;
    const cy = cell0.y + cell0.h * 0.5;
    try std.testing.expect(!(cx >= e.x and cx < e.x + e.w and cy >= e.y and cy < e.y + e.h));
}
