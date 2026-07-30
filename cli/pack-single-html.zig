//! Host-side single-HTML packer for kngn wasm apps.
//!
//! Embeds the wasm bytes (base64) and the JS glue into one HTML file by replacing
//! a single marker comment and its following module script tag. Does not rewrite
//! `fetch(` strings or wasm URLs inside the glue.
//!
//! Build-graph tool only: the executable is not installed to zig-out/.
//! All work runs at pack time (not per-frame / RT).

const std = @import("std");

/// Exactly one of these comments must appear in the HTML template, immediately
/// before the glue `<script type="module" src="...">` element.
pub const marker = "<!-- kngn:inline-module -->";

pub const AudioTransport = enum {
    none,
    worklet_shared,
    worklet_postmessage,

    pub fn fromString(s: []const u8) ?AudioTransport {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "worklet_shared")) return .worklet_shared;
        if (std.mem.eql(u8, s, "worklet_postmessage")) return .worklet_postmessage;
        return null;
    }

    pub fn name(self: AudioTransport) []const u8 {
        return switch (self) {
            .none => "none",
            .worklet_shared => "worklet_shared",
            .worklet_postmessage => "worklet_postmessage",
        };
    }
};

pub const PackError = error{
    MarkerMissing,
    MarkerDuplicate,
    MarkerNotFollowedByGlueScript,
    WorkletSharedNotAllowed,
    WorkletSourceRequired,
    ExternalScriptRemaining,
    ExternalStylesheet,
    ExternalImage,
    ExternalIframe,
    ExternalMedia,
    OutOfMemory,
};

pub const PackOptions = struct {
    html_template: []const u8,
    js_source: []const u8,
    wasm_bytes: []const u8,
    wasm_filename: []const u8,
    audio: AudioTransport,
    /// Required when audio is worklet_postmessage.
    worklet_source: ?[]const u8 = null,
    shared_memory: bool = false,
};

/// Standard base64 encode of `source` into a newly allocated string.
pub fn base64EncodeAlloc(allocator: std.mem.Allocator, source: []const u8) error{OutOfMemory}![]u8 {
    const enc = std.base64.standard.Encoder;
    const len = enc.calcSize(source.len);
    const out = try allocator.alloc(u8, len);
    _ = enc.encode(out, source);
    return out;
}

/// Count non-overlapping occurrences of `marker` in `html`.
pub fn countMarkers(html: []const u8) usize {
    var count: usize = 0;
    var rest = html;
    while (std.mem.indexOf(u8, rest, marker)) |idx| {
        count += 1;
        rest = rest[idx + marker.len ..];
    }
    return count;
}

/// Skip ASCII whitespace starting at `start`.
fn skipWs(html: []const u8, start: usize) usize {
    var i = start;
    while (i < html.len and std.ascii.isWhitespace(html[i])) : (i += 1) {}
    return i;
}

/// Find the `>` that ends an open tag, ignoring `>` inside quoted attribute values.
pub fn findOpenTagEnd(html: []const u8, start: usize) ?usize {
    var i = start;
    var quote: ?u8 = null;
    while (i < html.len) : (i += 1) {
        const c = html[i];
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '>') return i;
    }
    return null;
}

/// After the marker, require a glue script tag shaped like:
///   <script type="module" src="./kngn.js"></script>
/// Attributes are parsed (not substring-matched). `type` must be `module` and
/// `src` must end with `kngn.js`. Returns the end index (exclusive) of `</script>`.
pub fn findGlueScriptEnd(html: []const u8, after_marker: usize) PackError!usize {
    const at = skipWs(html, after_marker);
    if (at + 7 > html.len or !std.mem.startsWith(u8, html[at..], "<script")) {
        return PackError.MarkerNotFollowedByGlueScript;
    }
    const tag_end = findOpenTagEnd(html, at) orelse return PackError.MarkerNotFollowedByGlueScript;
    const open_tag = html[at .. tag_end + 1];
    const typ = attrValue(open_tag, "type") orelse return PackError.MarkerNotFollowedByGlueScript;
    if (!std.mem.eql(u8, typ, "module")) return PackError.MarkerNotFollowedByGlueScript;
    const src = attrValue(open_tag, "src") orelse return PackError.MarkerNotFollowedByGlueScript;
    // Accept "./kngn.js", "kngn.js", or a path ending in /kngn.js — reject other modules.
    if (!(std.mem.endsWith(u8, src, "kngn.js") or std.mem.eql(u8, src, "kngn.js"))) {
        return PackError.MarkerNotFollowedByGlueScript;
    }
    const close = std.mem.indexOfPos(u8, html, tag_end + 1, "</script>") orelse return PackError.MarkerNotFollowedByGlueScript;
    return close + "</script>".len;
}

/// JSON/JS string literal safe for embedding inside `<script type="module">`.
/// Escapes `\`, `"`, control bytes, `<` (so `</script>` cannot break out), and U+2028/U+2029.
fn jsStringLiteral(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, '"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        // UTF-8 U+2028 (e2 80 a8) / U+2029 (e2 80 a9) as LS/PS line terminators in JS.
        if (c == 0xe2 and i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0xa8 or s[i + 2] == 0xa9)) {
            if (s[i + 2] == 0xa8) {
                try list.appendSlice(allocator, "\\u2028");
            } else {
                try list.appendSlice(allocator, "\\u2029");
            }
            i += 3;
            continue;
        }
        switch (c) {
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '"' => try list.appendSlice(allocator, "\\\""),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            '<' => try list.appendSlice(allocator, "\\u003c"),
            '>' => try list.appendSlice(allocator, "\\u003e"),
            0...8, 11, 12, 14...31 => {
                var buf: [6]u8 = undefined;
                const hex = std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{c}) catch unreachable;
                try list.appendSlice(allocator, hex);
            },
            else => try list.append(allocator, c),
        }
        i += 1;
    }
    try list.append(allocator, '"');
    return try list.toOwnedSlice(allocator);
}

/// Build the packed HTML. Caller owns the returned slice.
pub fn packHtml(allocator: std.mem.Allocator, opts: PackOptions) PackError![]u8 {
    switch (opts.audio) {
        .worklet_shared => return PackError.WorkletSharedNotAllowed,
        .worklet_postmessage => {
            if (opts.worklet_source == null) return PackError.WorkletSourceRequired;
        },
        .none => {},
    }

    const n = countMarkers(opts.html_template);
    if (n == 0) return PackError.MarkerMissing;
    if (n > 1) return PackError.MarkerDuplicate;

    const marker_idx = std.mem.indexOf(u8, opts.html_template, marker).?;
    const glue_end = try findGlueScriptEnd(opts.html_template, marker_idx + marker.len);

    const b64 = try base64EncodeAlloc(allocator, opts.wasm_bytes);
    defer allocator.free(b64);

    const wasm_lit = try jsStringLiteral(allocator, opts.wasm_filename);
    defer allocator.free(wasm_lit);
    const transport_lit = try jsStringLiteral(allocator, opts.audio.name());
    defer allocator.free(transport_lit);

    var worklet_lit: ?[]u8 = null;
    defer if (worklet_lit) |w| allocator.free(w);
    if (opts.worklet_source) |ws| {
        worklet_lit = try jsStringLiteral(allocator, ws);
    }

    var prelude: std.ArrayList(u8) = .empty;
    defer prelude.deinit(allocator);
    try prelude.appendSlice(allocator, "<script type=\"module\">\n");
    try prelude.appendSlice(allocator, "globalThis.__kngnEmbedded = {\n");
    try prelude.appendSlice(allocator, "  embedded: true,\n");
    try prelude.appendSlice(allocator, "  wasmBase64: \"");
    try prelude.appendSlice(allocator, b64);
    try prelude.appendSlice(allocator, "\",\n");
    try prelude.appendSlice(allocator, "  wasm: ");
    try prelude.appendSlice(allocator, wasm_lit);
    try prelude.appendSlice(allocator, ",\n");
    try prelude.appendSlice(allocator, "  audioTransport: ");
    try prelude.appendSlice(allocator, transport_lit);
    try prelude.appendSlice(allocator, ",\n");
    try prelude.appendSlice(allocator, "  sharedMemory: ");
    try prelude.appendSlice(allocator, if (opts.shared_memory) "true" else "false");
    try prelude.appendSlice(allocator, ",\n");
    if (worklet_lit) |wl| {
        try prelude.appendSlice(allocator, "  workletSource: ");
        try prelude.appendSlice(allocator, wl);
        try prelude.appendSlice(allocator, ",\n");
    }
    try prelude.appendSlice(allocator, "};\n");
    try prelude.appendSlice(allocator, opts.js_source);
    if (opts.js_source.len == 0 or opts.js_source[opts.js_source.len - 1] != '\n') {
        try prelude.append(allocator, '\n');
    }
    try prelude.appendSlice(allocator, "</script>");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, opts.html_template[0..marker_idx]);
    try out.appendSlice(allocator, prelude.items);
    try out.appendSlice(allocator, opts.html_template[glue_end..]);

    const packed_html = try out.toOwnedSlice(allocator);
    errdefer allocator.free(packed_html);

    try assertSelfContained(packed_html);
    return packed_html;
}

/// Markup self-containment: no external script/link/img/iframe/media references.
/// Inline script bodies may still mention `fetch` or `.wasm` (fallback glue); those
/// are not treated as external references.
/// Open tags are scanned with quote-aware `>` detection so `alt=">"` cannot hide `src=`.
pub fn assertSelfContained(html: []const u8) PackError!void {
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] != '<') {
            i += 1;
            continue;
        }
        // Skip comments
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse break;
            i = end + 3;
            continue;
        }
        const tag_end = findOpenTagEnd(html, i) orelse break;
        const tag = html[i .. tag_end + 1];
        const name = tagName(tag);

        if (std.ascii.eqlIgnoreCase(name, "script")) {
            if (hasAttr(tag, "src")) {
                const src = attrValue(tag, "src") orelse return PackError.ExternalScriptRemaining;
                if (!isDataOrEmpty(src)) return PackError.ExternalScriptRemaining;
            }
            // Advance past the matching </script> so inline content is not re-scanned as markup.
            const close = std.mem.indexOfPos(u8, html, tag_end + 1, "</script>") orelse (tag_end + 1);
            i = if (close + 9 <= html.len) close + 9 else tag_end + 1;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "link")) {
            if (hasAttr(tag, "href")) {
                const href = attrValue(tag, "href") orelse return PackError.ExternalStylesheet;
                if (!isDataOrEmpty(href)) return PackError.ExternalStylesheet;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "img")) {
            if (hasAttr(tag, "src")) {
                const src = attrValue(tag, "src") orelse return PackError.ExternalImage;
                if (!isDataOrEmpty(src)) return PackError.ExternalImage;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "iframe")) {
            if (hasAttr(tag, "src")) {
                const src = attrValue(tag, "src") orelse return PackError.ExternalIframe;
                if (!isDataOrEmpty(src)) return PackError.ExternalIframe;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "audio") or std.ascii.eqlIgnoreCase(name, "video")) {
            if (hasAttr(tag, "src")) {
                const src = attrValue(tag, "src") orelse return PackError.ExternalMedia;
                if (!isDataOrEmpty(src)) return PackError.ExternalMedia;
            }
        }
        i = tag_end + 1;
    }
}

fn tagName(open_tag: []const u8) []const u8 {
    // open_tag starts with '<'
    var i: usize = 1;
    if (i < open_tag.len and open_tag[i] == '/') i += 1;
    const start = i;
    while (i < open_tag.len and !std.ascii.isWhitespace(open_tag[i]) and open_tag[i] != '>' and open_tag[i] != '/') : (i += 1) {}
    return open_tag[start..i];
}

fn hasAttr(open_tag: []const u8, attr: []const u8) bool {
    return attrValue(open_tag, attr) != null;
}

/// Best-effort attribute value extractor for simple HTML open tags.
fn attrValue(open_tag: []const u8, attr: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (search_from < open_tag.len) {
        const idx = std.mem.indexOfPos(u8, open_tag, search_from, attr) orelse return null;
        // Ensure attr is a whole attribute name (boundary before).
        if (idx > 0) {
            const prev = open_tag[idx - 1];
            if (!std.ascii.isWhitespace(prev) and prev != '<') {
                search_from = idx + 1;
                continue;
            }
        }
        var i = idx + attr.len;
        i = skipWs(open_tag, i);
        if (i >= open_tag.len or open_tag[i] != '=') {
            search_from = idx + 1;
            continue;
        }
        i += 1;
        i = skipWs(open_tag, i);
        if (i >= open_tag.len) return null;
        if (open_tag[i] == '"' or open_tag[i] == '\'') {
            const q = open_tag[i];
            const vstart = i + 1;
            const vend = std.mem.indexOfScalarPos(u8, open_tag, vstart, q) orelse return open_tag[vstart..];
            return open_tag[vstart..vend];
        }
        const vstart = i;
        while (i < open_tag.len and !std.ascii.isWhitespace(open_tag[i]) and open_tag[i] != '>') : (i += 1) {}
        return open_tag[vstart..i];
    }
    return null;
}

fn isDataOrEmpty(url: []const u8) bool {
    if (url.len == 0) return true;
    if (std.mem.startsWith(u8, url, "data:")) return true;
    return false;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const CliArgs = struct {
    html: []const u8,
    js: []const u8,
    wasm: []const u8,
    out: []const u8,
    audio: AudioTransport = .none,
    wasm_name: []const u8,
    worklet: ?[]const u8 = null,
    shared_memory: bool = false,
};

fn parseArgs(it: *std.process.Args.Iterator) !CliArgs {
    var html: ?[]const u8 = null;
    var js: ?[]const u8 = null;
    var wasm: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var audio: AudioTransport = .none;
    var wasm_name: ?[]const u8 = null;
    var worklet: ?[]const u8 = null;
    var shared_memory = false;

    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--html")) {
            html = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--js")) {
            js = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--wasm")) {
            wasm = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--out")) {
            out = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--audio")) {
            const v = it.next() orelse return error.MissingValue;
            audio = AudioTransport.fromString(v) orelse return error.BadAudio;
        } else if (std.mem.eql(u8, a, "--wasm-name")) {
            wasm_name = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--worklet")) {
            worklet = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--shared-memory")) {
            shared_memory = true;
        } else {
            std.log.err("unknown argument: {s}", .{a});
            return error.UnknownArg;
        }
    }

    return .{
        .html = html orelse return error.MissingHtml,
        .js = js orelse return error.MissingJs,
        .wasm = wasm orelse return error.MissingWasm,
        .out = out orelse return error.MissingOut,
        .audio = audio,
        .wasm_name = wasm_name orelse return error.MissingWasmName,
        .worklet = worklet,
        .shared_memory = shared_memory,
    };
}

fn readFileLimit(io: std.Io, gpa: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    _ = it.next(); // program name

    const cli = parseArgs(&it) catch {
        std.log.err(
            "usage: pack-single-html --html T.html --js kngn.js --wasm app.wasm --out out.html --wasm-name name.wasm --audio none|worklet_postmessage [--worklet worklet.js] [--shared-memory]",
            .{},
        );
        std.process.exit(2);
    };

    const html = try readFileLimit(io, gpa, cli.html, 16 * 1024 * 1024);
    defer gpa.free(html);
    const js = try readFileLimit(io, gpa, cli.js, 16 * 1024 * 1024);
    defer gpa.free(js);
    const wasm = try readFileLimit(io, gpa, cli.wasm, 64 * 1024 * 1024);
    defer gpa.free(wasm);
    const worklet_src: ?[]u8 = if (cli.worklet) |wp|
        try readFileLimit(io, gpa, wp, 16 * 1024 * 1024)
    else
        null;
    defer if (worklet_src) |w| gpa.free(w);

    const packed_html = packHtml(gpa, .{
        .html_template = html,
        .js_source = js,
        .wasm_bytes = wasm,
        .wasm_filename = cli.wasm_name,
        .audio = cli.audio,
        .worklet_source = worklet_src,
        .shared_memory = cli.shared_memory,
    }) catch |err| {
        std.log.err("pack failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer gpa.free(packed_html);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cli.out, .data = packed_html });
}

// ---------------------------------------------------------------------------
// Unit tests (host-only; step name test-pack-single-html)
// ---------------------------------------------------------------------------

test "base64 encode matches known vector" {
    const gpa = std.testing.allocator;
    // "hello" → aGVsbG8=
    const got = try base64EncodeAlloc(gpa, "hello");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("aGVsbG8=", got);
}

test "pack with one marker inserts inline module" {
    const gpa = std.testing.allocator;
    const html =
        \\<!DOCTYPE html><html><body data-wasm="demo.wasm">
        \\<!-- kngn:inline-module -->
        \\<script type="module" src="./kngn.js"></script>
        \\</body></html>
    ;
    const js = "export async function boot(){}\nif (!globalThis.__kngnManualBoot) boot();\n";
    const out = try packHtml(gpa, .{
        .html_template = html,
        .js_source = js,
        .wasm_bytes = "hi",
        .wasm_filename = "demo.wasm",
        .audio = .none,
    });
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, marker) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "src=\"./kngn.js\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__kngnEmbedded") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "wasmBase64:") != null);
    // "hi" base64 is aGk=
    try std.testing.expect(std.mem.indexOf(u8, out, "aGk=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "export async function boot") != null);
}

test "marker missing fails" {
    const gpa = std.testing.allocator;
    const html = "<html><script type=\"module\" src=\"./kngn.js\"></script></html>";
    const err = packHtml(gpa, .{
        .html_template = html,
        .js_source = "//js",
        .wasm_bytes = "",
        .wasm_filename = "x.wasm",
        .audio = .none,
    });
    try std.testing.expectError(PackError.MarkerMissing, err);
}

test "marker duplicate fails" {
    const gpa = std.testing.allocator;
    const html =
        \\<!-- kngn:inline-module -->
        \\<script type="module" src="./kngn.js"></script>
        \\<!-- kngn:inline-module -->
        \\<script type="module" src="./kngn.js"></script>
    ;
    const err = packHtml(gpa, .{
        .html_template = html,
        .js_source = "//js",
        .wasm_bytes = "",
        .wasm_filename = "x.wasm",
        .audio = .none,
    });
    try std.testing.expectError(PackError.MarkerDuplicate, err);
}

test "marker not followed by glue script fails" {
    const gpa = std.testing.allocator;
    const html =
        \\<!-- kngn:inline-module -->
        \\<div>nope</div>
    ;
    const err = packHtml(gpa, .{
        .html_template = html,
        .js_source = "//js",
        .wasm_bytes = "",
        .wasm_filename = "x.wasm",
        .audio = .none,
    });
    try std.testing.expectError(PackError.MarkerNotFollowedByGlueScript, err);
}

test "worklet_shared single HTML fails" {
    const gpa = std.testing.allocator;
    const html =
        \\<!-- kngn:inline-module -->
        \\<script type="module" src="./kngn.js"></script>
    ;
    const err = packHtml(gpa, .{
        .html_template = html,
        .js_source = "//js",
        .wasm_bytes = "",
        .wasm_filename = "x.wasm",
        .audio = .worklet_shared,
        .shared_memory = true,
    });
    try std.testing.expectError(PackError.WorkletSharedNotAllowed, err);
}

test "worklet_postmessage without worklet source fails" {
    const gpa = std.testing.allocator;
    const html =
        \\<!-- kngn:inline-module -->
        \\<script type="module" src="./kngn.js"></script>
    ;
    const err = packHtml(gpa, .{
        .html_template = html,
        .js_source = "//js",
        .wasm_bytes = "",
        .wasm_filename = "x.wasm",
        .audio = .worklet_postmessage,
        .worklet_source = null,
    });
    try std.testing.expectError(PackError.WorkletSourceRequired, err);
}

test "external script remaining is rejected by self-containment" {
    const gpa = std.testing.allocator;
    // Template keeps a second external script after the marker glue.
    const html =
        \\<!-- kngn:inline-module -->
        \\<script type="module" src="./kngn.js"></script>
        \\<script src="./other.js"></script>
    ;
    const err = packHtml(gpa, .{
        .html_template = html,
        .js_source = "//js",
        .wasm_bytes = "",
        .wasm_filename = "x.wasm",
        .audio = .none,
    });
    try std.testing.expectError(PackError.ExternalScriptRemaining, err);
}

test "countMarkers" {
    try std.testing.expectEqual(@as(usize, 0), countMarkers("no marker here"));
    try std.testing.expectEqual(@as(usize, 1), countMarkers("a " ++ marker ++ " b"));
    try std.testing.expectEqual(@as(usize, 2), countMarkers(marker ++ "x" ++ marker));
}

test "self-containment catches img with gt in quoted alt" {
    // First `>` is inside alt=">"; must not truncate the tag before src=.
    const html = "<html><body><img alt=\">\" src=\"https://example.com/x.png\"></body></html>";
    try std.testing.expectError(PackError.ExternalImage, assertSelfContained(html));
}

test "self-containment catches link stylesheet with gt in quoted title" {
    const html = "<html><head><link rel=\"stylesheet\" title=\"a>b\" href=\"https://example.com/x.css\"></head></html>";
    try std.testing.expectError(PackError.ExternalStylesheet, assertSelfContained(html));
}

test "self-containment catches iframe with gt in quoted title" {
    const html = "<html><body><iframe title=\"a>b\" src=\"https://example.com/\"></iframe></body></html>";
    try std.testing.expectError(PackError.ExternalIframe, assertSelfContained(html));
}

test "self-containment catches audio and video external src" {
    try std.testing.expectError(
        PackError.ExternalMedia,
        assertSelfContained("<html><audio src=\"https://example.com/a.mp3\"></audio></html>"),
    );
    try std.testing.expectError(
        PackError.ExternalMedia,
        assertSelfContained("<html><video src=\"https://example.com/v.mp4\"></video></html>"),
    );
}

test "jsStringLiteral escapes script close and line separators" {
    const gpa = std.testing.allocator;
    const lit = try jsStringLiteral(gpa, "</script>\u{2028}\u{2029}");
    defer gpa.free(lit);
    try std.testing.expect(std.mem.indexOf(u8, lit, "</script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, lit, "\\u003c") != null);
    try std.testing.expect(std.mem.indexOf(u8, lit, "\\u2028") != null);
    try std.testing.expect(std.mem.indexOf(u8, lit, "\\u2029") != null);
}

test "pack rejects non-glue script after marker" {
    const gpa = std.testing.allocator;
    const html =
        \\<!-- kngn:inline-module -->
        \\<script type="module" src="./other.js"></script>
    ;
    const err = packHtml(gpa, .{
        .html_template = html,
        .js_source = "//js",
        .wasm_bytes = "",
        .wasm_filename = "x.wasm",
        .audio = .none,
    });
    try std.testing.expectError(PackError.MarkerNotFollowedByGlueScript, err);
}

test "pack with worklet source containing script close stays safe" {
    const gpa = std.testing.allocator;
    const html =
        \\<!-- kngn:inline-module -->
        \\<script type="module" src="./kngn.js"></script>
    ;
    const worklet = "const s = \"</script>\";\n";
    const out = try packHtml(gpa, .{
        .html_template = html,
        .js_source = "export async function boot(){}\n",
        .wasm_bytes = "x",
        .wasm_filename = "x.wasm",
        .audio = .worklet_postmessage,
        .worklet_source = worklet,
    });
    defer gpa.free(out);
    // Embedded worklet must not introduce a raw </script> breakout sequence.
    try std.testing.expect(std.mem.indexOf(u8, out, "\\u003c") != null);
    var count: usize = 0;
    var rest = out;
    while (std.mem.indexOf(u8, rest, "</script>")) |idx| {
        count += 1;
        rest = rest[idx + 9 ..];
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}
