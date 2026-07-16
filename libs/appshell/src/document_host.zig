//! 文書フォーマットから独立した document lifecycle 管理。
//!
//! ホットパス宣言: 状態遷移、callback、path の所有、タイトル生成はすべてイベント時のみ。
//! フレーム毎・全画素・RT 経路では実行しない。

const std = @import("std");

pub const NameState = enum { untitled, named };
pub const EditState = enum { clean, dirty };
pub const Confirmation = enum { none, close, new, open };

pub const Result = enum {
    applied,
    allowed,
    confirmation_required,
    needs_save_as,
    rejected,
    canceled,
};

pub const PendingIntent = union(enum) {
    close,
    new_document,
    open: []const u8,
};

pub const Callbacks = struct {
    ctx: *anyopaque,
    newDocument: *const fn (ctx: *anyopaque) anyerror!void,
    openDocument: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
    saveDocument: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
};

pub const DocumentHost = struct {
    allocator: std.mem.Allocator,
    callbacks: Callbacks,
    current_path: ?[]u8 = null,
    pending_path: ?[]u8 = null,
    pending_kind: Confirmation = .none,
    dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator, callbacks: Callbacks) DocumentHost {
        return .{ .allocator = allocator, .callbacks = callbacks };
    }

    pub fn deinit(self: *DocumentHost) void {
        self.freePath(&self.current_path);
        self.freePath(&self.pending_path);
    }

    pub fn nameState(self: *const DocumentHost) NameState {
        return if (self.current_path == null) .untitled else .named;
    }

    pub fn editState(self: *const DocumentHost) EditState {
        return if (self.dirty) .dirty else .clean;
    }

    pub fn confirmation(self: *const DocumentHost) Confirmation {
        return self.pending_kind;
    }

    pub fn isDirty(self: *const DocumentHost) bool {
        return self.dirty;
    }

    pub fn currentPath(self: *const DocumentHost) ?[]const u8 {
        return self.current_path;
    }

    pub fn pendingPath(self: *const DocumentHost) ?[]const u8 {
        return self.pending_path;
    }

    pub fn pendingIntent(self: *const DocumentHost) ?PendingIntent {
        return switch (self.pending_kind) {
            .none => null,
            .close => .close,
            .new => .new_document,
            .open => .{ .open = self.pending_path.? },
        };
    }

    pub fn markDirty(self: *DocumentHost) void {
        if (self.pending_kind == .none) self.dirty = true;
    }

    pub fn newDocument(self: *DocumentHost) !Result {
        if (self.pending_kind != .none) return .rejected;
        if (self.dirty) {
            self.pending_kind = .new;
            return .confirmation_required;
        }
        try self.callbacks.newDocument(self.callbacks.ctx);
        self.clearCurrentPath();
        self.dirty = false;
        return .applied;
    }

    pub fn open(self: *DocumentHost, path: []const u8) !Result {
        if (self.pending_kind != .none or path.len == 0) return .rejected;
        if (self.dirty) {
            try self.setPendingPath(path);
            self.pending_kind = .open;
            return .confirmation_required;
        }
        try self.callbacks.openDocument(self.callbacks.ctx, path);
        try self.setCurrentPath(path);
        self.dirty = false;
        return .applied;
    }

    pub fn save(self: *DocumentHost) !Result {
        if (self.pending_kind != .none) return .rejected;
        const path = self.current_path orelse return .needs_save_as;
        try self.callbacks.saveDocument(self.callbacks.ctx, path);
        self.dirty = false;
        return .applied;
    }

    pub fn saveAs(self: *DocumentHost, path: []const u8) !Result {
        if (self.pending_kind != .none or path.len == 0) return .rejected;
        try self.callbacks.saveDocument(self.callbacks.ctx, path);
        try self.setCurrentPath(path);
        self.dirty = false;
        return .applied;
    }

    pub fn requestClose(self: *DocumentHost) !Result {
        if (self.pending_kind != .none) return .rejected;
        if (!self.dirty) return .allowed;
        self.pending_kind = .close;
        return .confirmation_required;
    }

    /// 保存確認を実行する。named 文書は現在 path、untitled 文書は path 必須。
    /// pending new/open は保存成功後に対象 callback まで継続する。
    pub fn confirmSave(self: *DocumentHost, save_path: ?[]const u8) !Result {
        const pending = self.pending_kind;
        if (pending == .none) return .rejected;

        const was_untitled = self.current_path == null;
        const path = self.current_path orelse save_path orelse return .needs_save_as;
        try self.callbacks.saveDocument(self.callbacks.ctx, path);
        if (was_untitled) try self.setCurrentPath(path);
        self.dirty = false;

        switch (pending) {
            .close => {
                self.clearPending();
                return .allowed;
            },
            .new => {
                self.callbacks.newDocument(self.callbacks.ctx) catch return error.PendingOperationFailed;
                self.clearCurrentPath();
                self.clearPending();
                return .applied;
            },
            .open => {
                self.callbacks.openDocument(self.callbacks.ctx, self.pending_path.?) catch return error.PendingOperationFailed;
                try self.setCurrentPath(self.pending_path.?);
                self.clearPending();
                return .applied;
            },
            .none => unreachable,
        }
    }

    pub fn confirmDiscard(self: *DocumentHost) !Result {
        const pending = self.pending_kind;
        if (pending == .none) return .rejected;

        switch (pending) {
            .close => {
                self.dirty = false;
                self.clearPending();
                return .allowed;
            },
            .new => {
                try self.callbacks.newDocument(self.callbacks.ctx);
                self.clearCurrentPath();
                self.dirty = false;
                self.clearPending();
                return .applied;
            },
            .open => {
                try self.callbacks.openDocument(self.callbacks.ctx, self.pending_path.?);
                try self.setCurrentPath(self.pending_path.?);
                self.dirty = false;
                self.clearPending();
                return .applied;
            },
            .none => unreachable,
        }
    }

    pub fn confirmCancel(self: *DocumentHost) Result {
        if (self.pending_kind == .none) return .rejected;
        self.clearPending();
        self.dirty = true;
        return .canceled;
    }

    /// `buf` は呼び出し側が所有する。結果は `buf` 内の UTF-8 title slice。
    pub fn title(self: *const DocumentHost, buf: []u8) []const u8 {
        const base = if (self.current_path) |path| basename(path) else "Untitled";
        if (self.dirty) return std.fmt.bufPrint(buf, "{s} — edited", .{base}) catch buf[0..0];
        return std.fmt.bufPrint(buf, "{s}", .{base}) catch buf[0..0];
    }

    pub fn titleAlloc(self: *const DocumentHost) ![]u8 {
        var buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        return self.allocator.dupe(u8, self.title(&buf));
    }

    fn setCurrentPath(self: *DocumentHost, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        self.freePath(&self.current_path);
        self.current_path = owned;
    }

    fn setPendingPath(self: *DocumentHost, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        self.freePath(&self.pending_path);
        self.pending_path = owned;
    }

    fn clearCurrentPath(self: *DocumentHost) void {
        self.freePath(&self.current_path);
    }

    fn clearPending(self: *DocumentHost) void {
        self.pending_kind = .none;
        self.freePath(&self.pending_path);
    }

    fn freePath(self: *DocumentHost, path: *?[]u8) void {
        if (path.*) |owned| self.allocator.free(owned);
        path.* = null;
    }
};

fn basename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') return path[i + 1 ..];
    }
    return path;
}

const CallbackState = struct {
    calls: usize = 0,
    fail: bool = false,
    last_path: []const u8 = "",
};

fn cbNew(ctx: *anyopaque) !void {
    const state: *CallbackState = @ptrCast(@alignCast(ctx));
    state.calls += 1;
    if (state.fail) return error.CallbackFailed;
}

fn cbOpen(ctx: *anyopaque, path: []const u8) !void {
    const state: *CallbackState = @ptrCast(@alignCast(ctx));
    state.calls += 1;
    if (state.fail) return error.CallbackFailed;
    state.last_path = path;
}

fn cbSave(ctx: *anyopaque, path: []const u8) !void {
    const state: *CallbackState = @ptrCast(@alignCast(ctx));
    state.calls += 1;
    if (state.fail) return error.CallbackFailed;
    state.last_path = path;
}

fn testHost(state: *CallbackState) DocumentHost {
    return .init(std.testing.allocator, .{
        .ctx = state,
        .newDocument = cbNew,
        .openDocument = cbOpen,
        .saveDocument = cbSave,
    });
}

test "DocumentHost lifecycle, failures, and title" {
    var state: CallbackState = .{};
    var host = testHost(&state);
    defer host.deinit();

    try std.testing.expectEqual(NameState.untitled, host.nameState());
    try std.testing.expectEqual(EditState.clean, host.editState());
    var title_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Untitled", host.title(&title_buf));

    try std.testing.expectEqual(Result.applied, try host.newDocument());
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(Result.applied, try host.open("/tmp/name.pix"));
    try std.testing.expectEqualStrings("/tmp/name.pix", host.currentPath().?);
    try std.testing.expectEqualStrings("name.pix", host.title(&title_buf));
    host.markDirty();
    try std.testing.expectEqual(EditState.dirty, host.editState());
    try std.testing.expectEqualStrings("name.pix — edited", host.title(&title_buf));
    state.fail = true;
    try std.testing.expectError(error.CallbackFailed, host.save());
    try std.testing.expect(host.isDirty());
    try std.testing.expectEqualStrings("/tmp/name.pix", host.currentPath().?);
    state.fail = false;
    try std.testing.expectEqual(Result.applied, try host.save());

    host.markDirty();
    try std.testing.expectEqual(Result.confirmation_required, try host.requestClose());
    try std.testing.expectEqual(Confirmation.close, host.confirmation());
    try std.testing.expectEqual(Result.rejected, try host.open("other.pix"));
    try std.testing.expectEqual(Result.canceled, host.confirmCancel());
    try std.testing.expect(host.isDirty());
}

test "DocumentHost pending new/open all confirmation branches" {
    var state: CallbackState = .{};
    var host = testHost(&state);
    defer host.deinit();

    host.markDirty();
    try std.testing.expectEqual(Result.confirmation_required, try host.open("opened.pix"));
    try std.testing.expectEqual(Confirmation.open, host.confirmation());
    try std.testing.expectEqual(Result.applied, try host.confirmDiscard());
    try std.testing.expectEqualStrings("opened.pix", host.currentPath().?);
    try std.testing.expect(!host.isDirty());

    // named 文書は save_path が null でも現在 path へ保存して pending new を継続する。
    host.markDirty();
    try std.testing.expectEqual(Result.confirmation_required, try host.newDocument());
    try std.testing.expectEqual(Result.applied, try host.confirmSave(null));
    try std.testing.expectEqual(Confirmation.none, host.confirmation());
    try std.testing.expectEqual(NameState.untitled, host.nameState());
    try std.testing.expect(!host.isDirty());

    host.markDirty();
    try std.testing.expectEqual(Result.confirmation_required, try host.open("failed.pix"));
    state.fail = true;
    try std.testing.expectError(error.CallbackFailed, host.confirmDiscard());
    try std.testing.expectEqual(Confirmation.open, host.confirmation());
    try std.testing.expect(host.isDirty());

    // untitled 文書の close は save-as path が必須で、保存後に終了を許可する。
    var untitled_state: CallbackState = .{};
    var untitled_host = testHost(&untitled_state);
    defer untitled_host.deinit();
    untitled_host.markDirty();
    try std.testing.expectEqual(Result.confirmation_required, try untitled_host.requestClose());
    try std.testing.expectEqual(Result.needs_save_as, try untitled_host.confirmSave(null));
    try std.testing.expectEqual(Confirmation.close, untitled_host.confirmation());
    try std.testing.expectEqual(Result.allowed, try untitled_host.confirmSave("x.pix"));
    try std.testing.expectEqualStrings("x.pix", untitled_host.currentPath().?);
    try std.testing.expectEqual(Confirmation.none, untitled_host.confirmation());
    try std.testing.expect(!untitled_host.isDirty());
}

test "DocumentHost saveAs and clean close" {
    var state: CallbackState = .{};
    var host = testHost(&state);
    defer host.deinit();

    try std.testing.expectEqual(Result.needs_save_as, try host.save());
    try std.testing.expectEqual(Result.applied, try host.saveAs("/tmp/alias.pix"));
    try std.testing.expectEqualStrings("/tmp/alias.pix", host.currentPath().?);
    try std.testing.expectEqual(Result.allowed, try host.requestClose());
    try std.testing.expectEqual(Confirmation.none, host.confirmation());
}
