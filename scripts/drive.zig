//! drive: ヘッドレス検証 harness の live トランスポート（TCP loopback）driver CLI（TASK-32.2）。
//!
//! 背景起動したアプリ（`VP_HARNESS_LIVE=1` / `VP_HARNESS_PORT=<n>` で listen 中）へ、1接続=1リクエスト
//! =1レスポンスでコマンドを投げる。状態はアプリプロセス側に残る（接続は使い捨て）。
//!
//! 使い方:
//!   drive --port 54321 'inject key_down A; step 3; digest fb'
//!   drive --port-file /tmp/vp.port 'step 1; digest fb'
//!   （--port / --port-file 省略時は env VP_HARNESS_PORT / VP_HARNESS_PORT_FILE を参照）
//!
//! コマンド文字列は残り引数を空白連結したもの。harness 側は `;` / 改行で複数コマンドに分割する。
//! 送信後に write 側を half-close し、レスポンス（digest テキスト / snapshot パス）を stdout に出して終了する。
//!
//! 純 std + `std.Io.net` のみ（platform/audio 非依存）。mac/Linux/Windows で同一コード。

const std = @import("std");
const net = std.Io.net;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // 短命 CLI なので arena を使う（全 alloc はプロセス終了時に一括解放。手動 free / leak 報告なし）。
    const gpa = init.arena.allocator();

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    _ = it.next(); // program 名

    var port_opt: ?u16 = null;
    var port_file: ?[]const u8 = null;
    var cmd: std.ArrayList(u8) = .empty;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const v = it.next() orelse return die("--port は値が必要です\n");
            port_opt = std.fmt.parseInt(u16, v, 10) catch return die("--port の値が不正です\n");
        } else if (std.mem.eql(u8, arg, "--port-file")) {
            port_file = it.next() orelse return die("--port-file は値が必要です\n");
        } else {
            if (cmd.items.len > 0) try cmd.append(gpa, ' ');
            try cmd.appendSlice(gpa, arg);
        }
    }
    if (cmd.items.len == 0) return die("コマンド文字列がありません（例: drive --port-file /tmp/vp.port 'step 1; digest fb'）\n");

    // port 解決: --port > --port-file > env VP_HARNESS_PORT > env VP_HARNESS_PORT_FILE
    const port: u16 = port_opt orelse blk: {
        if (port_file) |pf| break :blk try readPortFile(io, gpa, pf);
        if (init.environ_map.get("VP_HARNESS_PORT")) |pe| {
            break :blk std.fmt.parseInt(u16, pe, 10) catch return die("VP_HARNESS_PORT の値が不正です\n");
        }
        if (init.environ_map.get("VP_HARNESS_PORT_FILE")) |pf| break :blk try readPortFile(io, gpa, pf);
        return die("port が不明です（--port / --port-file / VP_HARNESS_PORT / VP_HARNESS_PORT_FILE のいずれかを指定）\n");
    };

    // 接続 → 送信 → write half-close → レスポンス受信 → stdout
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        return die2("127.0.0.1 への接続に失敗しました: {s}\n", .{@errorName(err)});
    };
    defer stream.close(io);

    {
        var wbuf: [4096]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        try writer.interface.writeAll(cmd.items);
        try writer.interface.flush();
    }
    stream.shutdown(io, .send) catch {}; // EOF を相手に伝える（harness はここまで読む）

    var rbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    const resp = reader.interface.allocRemaining(gpa, std.Io.Limit.limited(1 << 20)) catch |err| {
        return die2("レスポンス受信に失敗しました: {s}\n", .{@errorName(err)});
    };

    var obuf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &obuf);
    try stdout.interface.writeAll(resp);
    try stdout.interface.flush();
}

fn readPortFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !u16 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.limited(64)) catch |err| {
        return die2("port file の読み込みに失敗しました {s}: {s}\n", .{ path, @errorName(err) });
    };
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    return std.fmt.parseInt(u16, trimmed, 10) catch return die("port file の内容が不正です\n");
}

fn die(msg: []const u8) error{DriveFailed} {
    std.debug.print("drive: {s}", .{msg});
    return error.DriveFailed;
}

fn die2(comptime fmt: []const u8, args: anytype) error{DriveFailed} {
    std.debug.print("drive: " ++ fmt, args);
    return error.DriveFailed;
}
