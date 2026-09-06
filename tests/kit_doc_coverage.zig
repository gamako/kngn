//! Verifies that the public surface of `kit` is reachable from the author-facing
//! documentation, and that the index does not rot.
//!
//! Five properties:
//!
//! 1. **Coverage** — every public name of `kit/kit.zig` appears in `docs/kit-tour.md`
//!    written as `kit.<name>`. Adding a name to the umbrella without documenting it
//!    fails this test.
//! 2. **Reachability** — `docs/app-authoring.md` links to the tour. An index nobody can
//!    find is not an index, and the defect this document set exists to close is exactly
//!    "the feature was there, the reader never found it".
//! 3. **Live references** — the paths both documents link to exist on disk, so the samples
//!    and sources they point at cannot silently move away from them.
//! 4. **Packaged references** — those paths are also inside `build.zig.zon`'s `.paths`. A
//!    checkout contains the whole tree, so existence alone would pass for a file the package
//!    does not ship, and the link would break only for someone who fetched it.
//! 5. **The way to the source** — section 5.3 of `docs/app-authoring.md` tells the reader
//!    that the option structs, not its own table, are the authority on what a widget call
//!    accepts. That sentence is only true if the section also shows the way there, so each
//!    named source file is required to be linked from inside it.
//!
//! ## Why `kit.<name>` and not the bare name
//!
//! Several public names are ordinary English words — `audio`, `control`, `font`, `png`.
//! Matching the bare word makes twenty of the twenty-three pass against prose that never
//! mentions the module, which is a check that cannot fail. The prefixed form is also the
//! shape a reader actually types, so demanding it keeps the document useful rather than
//! merely keyword-complete.
//!
//! ## What this does not check
//!
//! It is structural, not semantic. A name mentioned only inside a code block, or in a
//! sentence saying not to use it, or with a wrong description beside it, all pass. The
//! correctness of the prose is a review question and stays one.
//!
//! ## Why the declarations are parsed rather than scanned
//!
//! Indentation carries no syntactic meaning in Zig, so text cannot tell a top-level
//! declaration from a nested one: a `pub` declaration inside a struct may sit at column zero
//! while a top-level one may be indented. Matching text is therefore wrong in both
//! directions, and the direction that matters is the miss — a declaration the walk does not
//! see is never required to appear in the documentation, so the omission this file exists to
//! catch would pass silently. `rootDecls` answers the question the check is actually asking.
//!
//! Every path out of the walk that cannot answer it fails rather than returning "nothing
//! found", for the same reason.
//!
//! ## Where this runs
//!
//! Only from a checkout, and `build.zig` pins the working directory so the reference
//! check resolves the same way wherever it is invoked from. The documents it embeds are
//! covered by `build.zig.zon`'s `.paths`, so a fetched package still contains them.

const std = @import("std");

const kit_source = @embedFile("kit_source");
const kit_tour = @embedFile("kit_tour");
const app_authoring = @embedFile("app_authoring");
const manifest = @embedFile("manifest");

/// The directory both documents live in, which every relative link in them resolves against.
const docs_dir = "docs";

/// A public declaration of the umbrella module.
const PublicName = []const u8;

/// Collect the public top-level declarations of `kit/kit.zig`.
fn publicNames(gpa: std.mem.Allocator, source: [:0]const u8) ![]PublicName {
    var tree = try std.zig.Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return error.KitSourceDoesNotParse;

    var names: std.ArrayList(PublicName) = .empty;
    errdefer {
        // Each element is owned separately, so deinit alone would leak every name collected
        // before the failure.
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    for (tree.rootDecls()) |node| {
        const name: []const u8 = blk: {
            if (tree.fullVarDecl(node)) |decl| {
                if (decl.visib_token == null) continue;
                break :blk tree.tokenSlice(decl.ast.mut_token + 1);
            }
            var buf: [1]std.zig.Ast.Node.Index = undefined;
            if (tree.fullFnProto(&buf, node)) |proto| {
                if (proto.visib_token == null) continue;
                // A public function the walk cannot name is never demanded of the
                // documentation, so silence here would reintroduce the gap this parse closes.
                const token = proto.name_token orelse return error.UnnamedPublicFunction;
                break :blk tree.tokenSlice(token);
            }
            continue;
        };

        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try names.append(gpa, owned);
    }
    return names.toOwnedSlice(gpa);
}

/// Whether `haystack` contains `kit.<name>` as a whole identifier.
fn mentions(haystack: []const u8, name: []const u8) error{NameTooLong}!bool {
    var buf: [128]u8 = undefined;
    // Returning "not found" here would be the safe direction, but an error is honest: the
    // check could not look, which is different from having looked and found nothing.
    const needle = std.fmt.bufPrint(&buf, "kit.{s}", .{name}) catch return error.NameTooLong;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, needle)) |at| {
        from = at + needle.len;
        // Reject a longer identifier that merely starts with this one (`kit.gui` in `kit.gui_font`),
        // and a longer path that merely ends with it (`some_kit.gui`).
        const after = at + needle.len;
        if (after < haystack.len and (std.ascii.isAlphanumeric(haystack[after]) or haystack[after] == '_')) continue;
        if (at > 0) {
            const before = haystack[at - 1];
            if (std.ascii.isAlphanumeric(before) or before == '_' or before == '.') continue;
        }
        return true;
    }
    return false;
}

/// Every **inline** markdown link destination in `doc` (`[text](dest)`), skipping external
/// URLs and in-page anchors. Reference-style links are not collected, which is why
/// `rejectReferenceLinks` exists: an uncollected link is an unchecked one.
///
/// A `dest` carrying an anchor is checked as far as the file. Whether the heading exists is
/// not verified.
fn localLinks(gpa: std.mem.Allocator, doc: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, doc, from, "](")) |at| {
        const start = at + 2;
        // An unterminated link would end the scan and leave every later link unexamined, which
        // is the failure mode this whole file exists to avoid: a check that stops measuring and
        // stays green. Refuse the document instead.
        const end = std.mem.indexOfScalarPos(u8, doc, start, ')') orelse return error.MalformedMarkdownLink;
        from = end + 1;
        const dest = doc[start..end];
        if (dest.len == 0) continue;
        // Match the scheme, not the prefix: a local file named `http-something.md` is a path.
        if (std.mem.startsWith(u8, dest, "http://")) continue;
        if (std.mem.startsWith(u8, dest, "https://")) continue;
        if (dest[0] == '#') continue;
        // Drop an in-page anchor on an otherwise local path.
        const path = if (std.mem.indexOfScalar(u8, dest, '#')) |hash| dest[0..hash] else dest;
        if (path.len == 0) continue;
        try out.append(gpa, path);
    }
    return out.toOwnedSlice(gpa);
}

test "every public name of kit is indexed in the tour" {
    const gpa = std.testing.allocator;
    const names = try publicNames(gpa, kit_source);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }

    // A parse that yields nothing would satisfy every assertion below, so pin the shape first.
    try std.testing.expect(names.len > 0);

    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(gpa);
    for (names) |name| {
        if (!try mentions(kit_tour, name)) try missing.append(gpa, name);
    }

    if (missing.items.len != 0) {
        std.debug.print(
            \\
            \\{d} public name(s) of kit/kit.zig are missing from docs/kit-tour.md.
            \\Each must appear there written as `kit.<name>`:
            \\
        , .{missing.items.len});
        for (missing.items) |name| std.debug.print("  kit.{s}\n", .{name});
        return error.PublicNameNotDocumented;
    }
}

test "app-authoring links to the tour" {
    const gpa = std.testing.allocator;
    const links = try localLinks(gpa, app_authoring);
    defer gpa.free(links);

    for (links) |dest| {
        // Both documents sit in docs/, so a link between them is a bare file name.
        if (std.mem.eql(u8, dest, "kit-tour.md")) return;
    }
    std.debug.print(
        \\
        \\docs/app-authoring.md has no link to kit-tour.md.
        \\An index the reader cannot reach is not an index.
        \\
    , .{});
    return error.TourNotLinked;
}

/// Every local link in `doc` resolves to a file that is on disk.
///
/// `min_links` pins the shape before the loop runs: a document that stopped stating its
/// references as links would otherwise satisfy an empty loop and report nothing wrong.
fn assertLinksExist(gpa: std.mem.Allocator, doc: []const u8, doc_name: []const u8, min_links: usize) !void {
    const links = try localLinks(gpa, doc);
    defer gpa.free(links);
    try std.testing.expect(links.len >= min_links);

    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    var broken: usize = 0;
    for (links) |dest| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const joined = std.fmt.bufPrint(&buf, docs_dir ++ "/{s}", .{dest}) catch {
            broken += 1;
            continue;
        };
        cwd.access(io, joined, .{}) catch {
            std.debug.print("{s} points at a path that does not exist: {s}\n", .{ doc_name, dest });
            broken += 1;
        };
    }
    if (broken != 0) return error.DocumentReferenceMissing;
}

test "every path the tour points at exists" {
    try assertLinksExist(std.testing.allocator, kit_tour, "docs/kit-tour.md", 40);
}

test "every path app-authoring points at exists" {
    try assertLinksExist(std.testing.allocator, app_authoring, "docs/app-authoring.md", 20);
}

/// The entries of the manifest's top-level `.paths`.
///
/// Parsed as ZON rather than scanned, because `.paths` appears in a dependency block and in
/// the comments too. A text scan has to guess which one is the top-level field, and a wrong
/// guess can land on a set that happens to cover every link — passing while checking the
/// wrong thing. The parser answers by grammar, so there is nothing to guess.
fn manifestPaths(gpa: std.mem.Allocator, zon: [:0]const u8) ![]const []const u8 {
    const Manifest = struct { paths: []const []const u8 };
    const parsed = std.zon.parse.fromSliceAlloc(
        Manifest,
        gpa,
        zon,
        null,
        .{ .ignore_unknown_fields = true },
    ) catch return error.ManifestPathsUnreadable;
    return parsed.paths;
}

/// Every local link in `doc` lands inside `build.zig.zon`'s `.paths`.
///
/// A checkout holds the whole tree, so existence alone passes for a file the package does not
/// ship — and the link then breaks only for the reader who fetched it, which is the reader
/// these documents are written for.
fn assertLinksPackaged(gpa: std.mem.Allocator, doc: []const u8, doc_name: []const u8) !void {
    const paths = try manifestPaths(gpa, manifest);
    defer {
        for (paths) |entry| gpa.free(entry);
        gpa.free(paths);
    }
    try std.testing.expect(paths.len > 0);

    const links = try localLinks(gpa, doc);
    defer gpa.free(links);

    var outside: usize = 0;
    for (links) |dest| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const joined = std.fmt.bufPrint(&buf, docs_dir ++ "/{s}", .{dest}) catch {
            outside += 1;
            continue;
        };
        // Resolve `docs/../examples/x` to `examples/x` so it can be compared against `.paths`,
        // whose entries are relative to the build root.
        const rel = std.fs.path.resolvePosix(gpa, &.{joined}) catch {
            outside += 1;
            continue;
        };
        defer gpa.free(rel);
        const root_relative = std.mem.trimStart(u8, rel, "/");

        var covered = false;
        for (paths) |entry| {
            if (std.mem.eql(u8, root_relative, entry)) covered = true;
            if (std.mem.startsWith(u8, root_relative, entry) and
                root_relative.len > entry.len and root_relative[entry.len] == '/') covered = true;
        }
        if (!covered) {
            std.debug.print(
                "{s} links {s}, which build.zig.zon's .paths does not ship\n",
                .{ doc_name, root_relative },
            );
            outside += 1;
        }
    }
    if (outside != 0) return error.DocumentReferenceNotPackaged;
}

test "every path the tour points at is shipped in the package" {
    try assertLinksPackaged(std.testing.allocator, kit_tour, "docs/kit-tour.md");
}

test "every path app-authoring points at is shipped in the package" {
    try assertLinksPackaged(std.testing.allocator, app_authoring, "docs/app-authoring.md");
}

/// Fail on a reference-style link definition (`[label]: dest`).
///
/// `localLinks` only sees inline links, so a reference-style one would be invisible to every
/// check built on it — present in the document, pointing anywhere, and never examined. Rather
/// than let the coverage quietly shrink, both documents are held to inline links.
///
/// **What this catches**: a definition on one line, including inside a blockquote or a list
/// item. **What it does not**: the form CommonMark also permits where the label is split
/// across lines. Matching that needs a real Markdown parser, and hand-rolling one here would
/// repeat the mistake this file is built to avoid — so the limit is stated rather than
/// implied. The convention is enforced against ordinary authoring, not against effort.
fn rejectReferenceLinks(doc: []const u8, doc_name: []const u8) !void {
    var line_it = std.mem.splitScalar(u8, doc, '\n');
    while (line_it.next()) |line| {
        // A definition stays a definition inside a blockquote or a list item, so strip those
        // markers before looking for the label.
        var trimmed = std.mem.trim(u8, line, " \t\r");
        while (trimmed.len > 0 and (trimmed[0] == '>' or trimmed[0] == '-' or
            trimmed[0] == '*' or trimmed[0] == '+'))
        {
            trimmed = std.mem.trim(u8, trimmed[1..], " \t\r");
        }
        if (!std.mem.startsWith(u8, trimmed, "[")) continue;
        const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse continue;
        if (close + 1 < trimmed.len and trimmed[close + 1] == ':') {
            std.debug.print(
                "{s} uses a reference-style link, which the checks do not see: {s}\n",
                .{ doc_name, trimmed },
            );
            return error.ReferenceStyleLink;
        }
    }
}

/// The offset of the sole heading line that begins with `marker`.
///
/// A heading is a line **outside** a fenced code block, and all three qualifiers matter. Matching
/// `marker` anywhere would also match it mid-sentence; matching any line would also match a line
/// of a sample; and either wrong start yields a span that the check then passes over happily.
/// Uniqueness closes the rest: a second candidate is exactly the ambiguity that would otherwise
/// pick a region silently.
fn soleHeadingOffset(doc: []const u8, marker: []const u8) !usize {
    var found: ?usize = null;
    var fenced = false;
    var offset: usize = 0;
    var line_it = std.mem.splitScalar(u8, doc, '\n');
    while (line_it.next()) |line| {
        defer offset += line.len + 1;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```")) {
            fenced = !fenced;
            continue;
        }
        if (fenced) continue;
        if (!std.mem.startsWith(u8, line, marker)) continue;
        if (found != null) return error.AmbiguousSectionMarker;
        found = offset;
    }
    return found orelse error.SectionMarkerNotFound;
}

/// The span of `doc` between two headings, each of which must occur exactly once at the start
/// of a line. A renamed or duplicated heading fails rather than yielding a span that quietly
/// covers the wrong text — the failure mode this file exists to prevent.
fn sectionSlice(doc: []const u8, begin: []const u8, end: []const u8) ![]const u8 {
    const from = try soleHeadingOffset(doc, begin);
    const to = try soleHeadingOffset(doc, end);
    if (to <= from) return error.SectionMarkersOutOfOrder;
    return doc[from + begin.len .. to];
}

test "sectionSlice refuses a marker that is absent, duplicated, or out of order" {
    const doc = "### 5.3 A\nbody\n### 5.4 B\n";
    try std.testing.expectEqualStrings("A\nbody\n", try sectionSlice(doc, "### 5.3 ", "### 5.4 "));
    try std.testing.expectError(error.SectionMarkerNotFound, sectionSlice(doc, "### 9.9 ", "### 5.4 "));
    try std.testing.expectError(error.SectionMarkersOutOfOrder, sectionSlice(doc, "### 5.4 ", "### 5.3 "));

    const duplicated = "### 5.3 A\n### 5.4 B\n### 5.3 again\n";
    try std.testing.expectError(error.AmbiguousSectionMarker, sectionSlice(duplicated, "### 5.3 ", "### 5.4 "));

    // A marker that does not begin a line is prose, not a heading.
    const inline_mention = "see ### 5.3 for this\n### 5.4 B\n";
    try std.testing.expectError(error.SectionMarkerNotFound, sectionSlice(inline_mention, "### 5.3 ", "### 5.4 "));

    // A heading-shaped line inside a fence is a sample, not the section. Without this the check
    // would adopt the sample as the section start once the real heading was renamed away, and
    // report nothing wrong.
    const fenced_only = "```\n### 5.3 Fake\n```\n### 5.4 B\n";
    try std.testing.expectError(error.SectionMarkerNotFound, sectionSlice(fenced_only, "### 5.3 ", "### 5.4 "));

    const fenced_plus_real = "```\n### 5.3 Fake\n```\n### 5.3 Real\nbody\n### 5.4 B\n";
    try std.testing.expectEqualStrings("Real\nbody\n", try sectionSlice(fenced_plus_real, "### 5.3 ", "### 5.4 "));
}

/// The source files §5.3 sends the reader to. They are the answer to "what can this call be
/// asked to do?", which the widget table deliberately does not try to answer.
const widget_section_sources = [_][]const u8{
    "libs/gui/src/context.zig",
    "libs/gui/src/widgets.zig",
    "libs/gui/src/style.zig",
    "libs/gui/src/table.zig",
    "libs/gui/src/popup.zig",
    "libs/gui/src/font.zig",
    "libs/gui/src/gui.zig",
};

test "the widget section links every option-struct source it names as the authority" {
    const gpa = std.testing.allocator;
    const section = try sectionSlice(app_authoring, "### 5.3 ", "### 5.4 ");

    const links = try localLinks(gpa, section);
    defer gpa.free(links);

    // Counting links would pass for a section that gained unrelated ones and lost the
    // relevant ones, so each file is required by name.
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(gpa);
    for (widget_section_sources) |want| {
        var found = false;
        for (links) |dest| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const joined = std.fmt.bufPrint(&buf, docs_dir ++ "/{s}", .{dest}) catch continue;
            const rel = std.fs.path.resolvePosix(gpa, &.{joined}) catch continue;
            defer gpa.free(rel);
            if (std.mem.eql(u8, std.mem.trimStart(u8, rel, "/"), want)) found = true;
        }
        if (!found) try missing.append(gpa, want);
    }

    if (missing.items.len != 0) {
        std.debug.print(
            \\
            \\docs/app-authoring.md section 5.3 tells the reader the option structs are the
            \\authority, but does not link {d} of them. A reader who is not shown the way
            \\to the source reads the table as the whole story, which is the defect this
            \\section was written to close:
            \\
        , .{missing.items.len});
        for (missing.items) |name| std.debug.print("  {s}\n", .{name});
        return error.WidgetSectionSourceNotLinked;
    }
}

test "the tour uses only inline links, which are the ones the checks can see" {
    try rejectReferenceLinks(kit_tour, "docs/kit-tour.md");
}

test "app-authoring uses only inline links, which are the ones the checks can see" {
    try rejectReferenceLinks(app_authoring, "docs/app-authoring.md");
}
