//! Prepare-then-adopt document replacement for the pixel editor.
//!
//! Replacing the open document touches two kinds of state: the `Document` itself and the
//! working buffers whose size follows it (`Runtime`). Everything that can fail happens while
//! building a `Prepared` value that nothing else references yet. Adopting that value into
//! the application is then a sequence of moves and frees that returns no error, so a failed
//! load, sync import or recovery can never leave the application holding a document of one
//! size next to buffers of another, and never frees a resource it has already handed over.
//!
//! Contract for callers:
//! - While `Prepared.init` runs, no application state changes. On failure the caller holds
//!   nothing: the document passed in has been deinitialised as well.
//! - Adopting a `Prepared` value must not call anything that returns an error. The only
//!   allocation left after adoption is the palette copy, which follows the paint layer's
//!   out-of-memory policy (a panic) rather than returning.
//!
//! Hot path: event-time only (new document, open, sync import, recovery, resize).

const std = @import("std");
const paint = @import("paint");

/// Recorder settings that survive a document replacement.
pub const RecorderSettings = struct {
    pixel_perfect: bool = false,
    symmetry: paint.Symmetry = .off,
};

/// The working buffers whose size follows the document.
pub const Runtime = struct {
    recorder: paint.StrokeRecorder,
    /// Scratch canvas for brush and selection previews; mirrors the document's layer list.
    preview_canvas: paint.Canvas,
    preview_rec: paint.StrokeRecorder,
    onion_buf: []u32,
    onion_scratch: []u32,

    /// Allocates every buffer for a `w`×`h` document with `layer_count` layers; on failure
    /// nothing allocated here survives.
    pub fn init(gpa: std.mem.Allocator, w: u32, h: u32, layer_count: usize, settings: RecorderSettings) !Runtime {
        const n = @as(usize, w) * @as(usize, h);

        var recorder = try paint.StrokeRecorder.init(gpa, w, h);
        errdefer recorder.deinit(gpa);
        recorder.pixel_perfect = settings.pixel_perfect;
        recorder.symmetry = settings.symmetry;

        var preview_canvas = try paint.Canvas.init(gpa, w, h);
        errdefer preview_canvas.deinit();
        while (preview_canvas.layers.items.len < @max(layer_count, 1)) {
            _ = try preview_canvas.addLayer(gpa);
        }

        var preview_rec = try paint.StrokeRecorder.init(gpa, w, h);
        errdefer preview_rec.deinit(gpa);

        const onion_buf = try gpa.alloc(u32, n);
        errdefer gpa.free(onion_buf);
        const onion_scratch = try gpa.alloc(u32, n);

        return .{
            .recorder = recorder,
            .preview_canvas = preview_canvas,
            .preview_rec = preview_rec,
            .onion_buf = onion_buf,
            .onion_scratch = onion_scratch,
        };
    }

    pub fn deinit(self: *Runtime, gpa: std.mem.Allocator) void {
        self.recorder.deinit(gpa);
        self.preview_canvas.deinit();
        self.preview_rec.deinit(gpa);
        gpa.free(self.onion_buf);
        gpa.free(self.onion_scratch);
        self.* = undefined;
    }
};

/// A document together with the runtime that fits it, not yet owned by the application.
pub const Prepared = struct {
    doc: paint.Document,
    runtime: Runtime,

    /// Takes ownership of `doc`; on failure `doc` is deinitialised too.
    pub fn init(gpa: std.mem.Allocator, doc: paint.Document, settings: RecorderSettings) !Prepared {
        var owned = doc;
        errdefer owned.deinit();
        const runtime = try Runtime.init(gpa, owned.width, owned.height, owned.layers.items.len, settings);
        return .{ .doc = owned, .runtime = runtime };
    }

    pub fn deinit(self: *Prepared, gpa: std.mem.Allocator) void {
        self.doc.deinit();
        self.runtime.deinit(gpa);
        self.* = undefined;
    }
};

const testing = std.testing;

fn makeDocument(gpa: std.mem.Allocator, w: u32, h: u32, layer_count: usize) !paint.Document {
    var doc = try paint.Document.init(gpa, w, h);
    errdefer doc.deinit();
    while (doc.layers.items.len < layer_count) _ = try doc.addLayer(gpa);
    return doc;
}

test "Prepared.init leaks nothing at any failing allocation and fits the document when it succeeds" {
    const settings: RecorderSettings = .{ .pixel_perfect = true, .symmetry = .off };
    var failures: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        // The document is the caller's input, so it comes from the plain allocator.
        const doc = try makeDocument(testing.allocator, 12, 7, 3);
        var prepared = Prepared.init(gpa, doc, settings) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            failures += 1;
            continue;
        };
        defer prepared.deinit(gpa);
        try testing.expect(!failing.has_induced_failure);
        try testing.expectEqual(@as(u32, 12), prepared.doc.width);
        try testing.expectEqual(@as(usize, 12 * 7), prepared.runtime.onion_buf.len);
        try testing.expectEqual(@as(usize, 12 * 7), prepared.runtime.onion_scratch.len);
        try testing.expectEqual(@as(u32, 12), prepared.runtime.preview_canvas.width);
        try testing.expectEqual(@as(u32, 7), prepared.runtime.preview_canvas.height);
        try testing.expectEqual(@as(usize, 3), prepared.runtime.preview_canvas.layers.items.len);
        try testing.expect(prepared.runtime.recorder.pixel_perfect);
        try testing.expectEqual(paint.Symmetry.off, prepared.runtime.recorder.symmetry);
        break;
    }
    // A sweep that never failed would prove nothing about the failure paths.
    try testing.expect(failures > 0);
}

test "Runtime.init carries the recorder settings and creates at least one preview layer" {
    var runtime = try Runtime.init(testing.allocator, 4, 4, 0, .{ .pixel_perfect = false, .symmetry = .off });
    defer runtime.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), runtime.preview_canvas.layers.items.len);
    try testing.expect(!runtime.recorder.pixel_perfect);
}

test "decoding a single-layer document returns an error at every failing allocation" {
    var source = try makeDocument(testing.allocator, 5, 3, 1);
    defer source.deinit();
    // Give the layer content so that the file carries a cel and the decoder takes the path
    // that allocates pixels before registering them in the cel pool.
    source.activeCanvas().layerPixels(0)[0] = 0xFF112233;
    source.commitActiveLayerToCel(testing.allocator, 0);
    const bytes = try paint.document_io.encodeDocument(&source, testing.allocator);
    defer testing.allocator.free(bytes);

    var failures: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var decoded = paint.document_io.decodeDocument(bytes, failing.allocator()) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            continue;
        };
        defer decoded.deinit();
        try testing.expectEqual(@as(u32, 5), decoded.width);
        break;
    }
    try testing.expect(failures > 0);
}
