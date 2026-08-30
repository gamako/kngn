//! Verifies that the public surface of `kit` is reachable from the author-facing
//! documentation, and that the index does not rot.
//!
//! Four properties:
//!
//! 1. **Coverage** — every public name of `kit/kit.zig` appears in `docs/kit-tour.md`
//!    written as `kit.<name>`. Adding a name to the umbrella without documenting it
//!    fails this test.
//! 2. **Reachability** — `docs/app-authoring.md` links to the tour. An index nobody can
//!    find is not an index, and the defect this document set exists to close is exactly
//!    "the feature was there, the reader never found it".
//! 3. **Live references** — the paths the tour links to exist on disk, so the samples and
//!    sources it points at cannot silently move away from it.
//! 4. **Packaged references** — those paths are also inside `build.zig.zon`'s `.paths`. A
//!    checkout contains the whole tree, so existence alone would pass for a file the package
//!    does not ship, and the link would break only for someone who fetched it.
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

/// The tour's own directory, which every relative link in it resolves against.
const tour_dir = "docs";

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

test "every path the tour points at exists" {
    const gpa = std.testing.allocator;
    const links = try localLinks(gpa, kit_tour);
    defer gpa.free(links);

    // The tour states its sources and samples as links so that they are checkable at all.
    // A tour that stopped doing so would pass this test while checking nothing.
    try std.testing.expect(links.len >= 40);

    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    var broken: usize = 0;
    for (links) |dest| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const joined = std.fmt.bufPrint(&buf, tour_dir ++ "/{s}", .{dest}) catch {
            broken += 1;
            continue;
        };
        cwd.access(io, joined, .{}) catch {
            std.debug.print("docs/kit-tour.md points at a path that does not exist: {s}\n", .{dest});
            broken += 1;
        };
    }
    if (broken != 0) return error.TourReferenceMissing;
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

test "every path the tour points at is shipped in the package" {
    const gpa = std.testing.allocator;
    const paths = try manifestPaths(gpa, manifest);
    defer {
        for (paths) |entry| gpa.free(entry);
        gpa.free(paths);
    }
    try std.testing.expect(paths.len > 0);

    const links = try localLinks(gpa, kit_tour);
    defer gpa.free(links);

    var outside: usize = 0;
    for (links) |dest| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const joined = std.fmt.bufPrint(&buf, tour_dir ++ "/{s}", .{dest}) catch {
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
                "docs/kit-tour.md links {s}, which build.zig.zon's .paths does not ship\n",
                .{root_relative},
            );
            outside += 1;
        }
    }
    if (outside != 0) return error.TourReferenceNotPackaged;
}

/// Fail on a reference-style link definition (`[label]: dest`).
///
/// `localLinks` only sees inline links, so a reference-style one would be invisible to every
/// check built on it — present in the document, pointing anywhere, and never examined. Rather
/// than let the coverage quietly shrink, the tour is held to inline links.
///
/// **What this catches**: a definition on one line, including inside a blockquote or a list
/// item. **What it does not**: the form CommonMark also permits where the label is split
/// across lines. Matching that needs a real Markdown parser, and hand-rolling one here would
/// repeat the mistake this file is built to avoid — so the limit is stated rather than
/// implied. The convention is enforced against ordinary authoring, not against effort.
fn rejectReferenceLinks(doc: []const u8) !void {
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
                "docs/kit-tour.md uses a reference-style link, which the checks do not see: {s}\n",
                .{trimmed},
            );
            return error.ReferenceStyleLink;
        }
    }
}

test "the tour uses only inline links, which are the ones the checks can see" {
    try rejectReferenceLinks(kit_tour);
}
